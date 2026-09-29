import Combine
import Foundation

/// Local mirror of the user's Google Tasks. Every edit is applied here first (so the UI never waits on the
/// network) and then sent to Google through one serial queue, so edits reach the server in the order made.
/// Once the queue drains, the touched lists are re-fetched: the server's order and ids become the truth again.
@MainActor
final class TaskStore: ObservableObject {
    struct Row: Identifiable, Equatable {
        let task: TaskItem
        let depth: Int
        var id: String { task.id }
    }

    @Published private(set) var lists: [TaskList] = []
    @Published private(set) var selectedListID: String?
    /// The "Today" tab (due today or overdue, across all lists) instead of a single list.
    @Published private(set) var showingToday = UserDefaults.standard.object(forKey: "showingToday") as? Bool ?? true
    @Published private(set) var tasks: [String: [TaskItem]] = [:]
    @Published private(set) var isSyncing = false
    /// The task whose inline "new subtask" field is open.
    @Published var addingSubtaskTo: String?
    /// Dev builds only: sample data, edits stay local.
    @Published private(set) var isDemo = false

    /// Short messages for the toast.
    let messages = PassthroughSubject<String, Never>()
    /// Asks the view to put the cursor in the "Add a task" field.
    let focusAddField = PassthroughSubject<Void, Never>()

    private let auth: GoogleAuth
    private let api: TasksAPI
    private var writeChain: Task<Void, Never>?
    private var pendingWrites = 0
    /// Bumped by every local change: a fetch that started before one is stale and gets dropped.
    private var editGeneration = 0
    /// Local placeholder id → id Google assigned (tasks and lists created here).
    private var aliases: [String: String] = [:]
    private var touchedLists = Set<String>()
    private var loadedLists = Set<String>()
    private var reconcileWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(auth: GoogleAuth) {
        self.auth = auth
        api = TasksAPI(auth: auth)
        loadCache()
        auth.$isSignedIn
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] signedIn in
                guard let self else { return }
                if signedIn {
                    Task { await self.refresh() }
                } else {
                    self.resetAfterSignOut()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Reading

    var selectedList: TaskList? { lists.first { $0.id == selectedListID } }

    /// Open tasks in display order: each top-level task followed by its open subtasks.
    func openRows(in listID: String) -> [Row] {
        let open = (tasks[listID] ?? []).enumerated().filter { !$0.element.isCompleted }
        let ids = Set(open.map(\.element.id))
        func sorted(_ items: [(offset: Int, element: TaskItem)]) -> [TaskItem] {
            items.sorted { a, b in
                let pa = a.element.position ?? "", pb = b.element.position ?? ""
                return pa == pb ? a.offset < b.offset : pa < pb
            }
            .map(\.element)
        }
        // A subtask whose parent is completed shows up at the top level instead of disappearing.
        let tops = sorted(open.filter { $0.element.parent.map { !ids.contains($0) } ?? true })
        let children = Dictionary(grouping: open.filter { $0.element.parent.map(ids.contains) ?? false }) { $0.element.parent! }
        return tops.flatMap { top in
            [Row(task: top, depth: 0)] + sorted(children[top.id] ?? []).map { Row(task: $0, depth: 1) }
        }
    }

    func completedTasks(in listID: String) -> [TaskItem] {
        (tasks[listID] ?? []).filter(\.isCompleted).sorted { ($0.completed ?? "") > ($1.completed ?? "") }
    }

    struct Entry: Identifiable, Equatable {
        let listID: String
        let task: TaskItem
        var id: String { task.id }
    }

    struct Today: Equatable {
        var overdue: [Entry] = []
        var dueToday: [Entry] = []
        /// Tasks due by today that were completed today.
        var done: [Entry] = []
        var remaining: Int { overdue.count + dueToday.count }
        var progress: Double { done.isEmpty && remaining == 0 ? 0 : Double(done.count) / Double(done.count + remaining) }
        var allDone: Bool { remaining == 0 && !done.isEmpty }
    }

    /// What the menu bar counts: open tasks due today or earlier, in every list.
    var today: Today {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        var result = Today()
        for list in lists {
            for task in tasks[list.id] ?? [] {
                guard let due = task.dueDate, due < cal.date(byAdding: .day, value: 1, to: start)! else { continue }
                let entry = Entry(listID: list.id, task: task)
                if task.isCompleted {
                    if let done = task.completedDate, done >= start { result.done.append(entry) }
                } else if due < start {
                    result.overdue.append(entry)
                } else {
                    result.dueToday.append(entry)
                }
            }
        }
        result.overdue.sort { ($0.task.dueDate ?? .distantPast) < ($1.task.dueDate ?? .distantPast) }
        result.done.sort { ($0.task.completed ?? "") > ($1.task.completed ?? "") }
        return result
    }

    func listTitle(_ id: String) -> String { lists.first { $0.id == id }?.title ?? "" }

    func hasChildren(_ task: TaskItem, in listID: String) -> Bool {
        (tasks[listID] ?? []).contains { $0.parent == task.id && !$0.isCompleted }
    }

    // MARK: Sync

    func refresh() async {
        guard !isDemo, auth.isSignedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let generation = editGeneration
            let fetched = try await api.lists()
            if generation == editGeneration, pendingWrites == 0 {
                lists = fetched
                for id in loadedLists where !fetched.contains(where: { $0.id == id }) {
                    tasks[id] = nil
                    loadedLists.remove(id)
                }
            }
            if selectedListID.map({ id in !lists.contains { $0.id == id } }) ?? true {
                selectedListID = lists.first?.id
            }
            // The menu bar counts tasks from every list, so every list is kept loaded.
            if let id = selectedListID { try await reloadTasks(id) }
            for list in lists where list.id != selectedListID { try await reloadTasks(list.id) }
            scheduleSave()
        } catch {
            report(error)
        }
    }

    private func reloadTasks(_ listID: String) async throws {
        guard !listID.hasPrefix("local-") else { return }
        let generation = editGeneration
        let fetched = try await api.tasks(in: listID)
        // Edits made meanwhile would be overwritten; the queue re-fetches once it has drained.
        guard generation == editGeneration, pendingWrites == 0 else { return }
        tasks[listID] = fetched.filter { $0.deleted != true }
        loadedLists.insert(listID)
    }

    func select(listID: String) {
        guard lists.contains(where: { $0.id == listID }) else { return }
        addingSubtaskTo = nil
        selectedListID = listID
        setShowingToday(false)
        guard !isDemo else { return }
        UserDefaults.standard.set(listID, forKey: "selectedList")
        Task {
            do { try await reloadTasks(resolve(listID)) } catch { report(error) }
            scheduleSave()
        }
    }

    func selectToday() {
        addingSubtaskTo = nil
        setShowingToday(true)
    }

    private func setShowingToday(_ value: Bool) {
        showingToday = value
        UserDefaults.standard.set(value, forKey: "showingToday")
    }

    /// Tabs are Today followed by the lists; -1 stands for Today.
    func selectList(offset: Int) {
        guard !lists.isEmpty else { return }
        let index = showingToday ? -1 : (lists.firstIndex { $0.id == selectedListID } ?? 0)
        let count = lists.count + 1
        selectList(at: ((index + 1 + offset) % count + count) % count - 1)
    }

    func selectList(at index: Int) {
        if index == -1 { return selectToday() }
        guard lists.indices.contains(index) else { return }
        select(listID: lists[index].id)
    }

    private func resetAfterSignOut() {
        writeChain?.cancel()
        lists = []
        tasks = [:]
        selectedListID = nil
        loadedLists = []
        aliases = [:]
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    // MARK: Task edits

    /// Adds to `listID`, or from the Today tab to the first list with today's date.
    func addTask(title: String, parent: TaskItem? = nil, in listID: String? = nil, dueToday: Bool = false) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let listID = listID ?? selectedListID ?? lists.first?.id else { return }
        let due = dueToday ? TaskItem.dueString(for: Date()) : nil
        let localID = "local-" + UUID().uuidString
        // New top-level tasks go first (as in Google Tasks); new subtasks go last under their parent.
        let previous = parent.flatMap { p in openRows(in: listID).last { $0.task.parent == p.id }?.task.id }
        var item = TaskItem(id: localID, title: title, status: "needsAction", due: due, parent: parent?.id)
        item.position = parent == nil ? "" : "~"
        change(listID) { $0.insert(item, at: 0) }
        var fields: [String: Any] = ["title": title]
        if let due { fields["due"] = due }
        enqueue(listID) { [self] in
            let created = try await api.insertTask(in: resolve(listID), fields: fields,
                                                   parent: parent.map { resolve($0.id) },
                                                   previous: previous.map(resolve))
            aliases[localID] = created.id
        }
    }

    func setCompleted(_ task: TaskItem, _ completed: Bool, in listID: String) {
        // Completing a task completes its open subtasks too, like Google Tasks does.
        let children = completed ? (tasks[listID] ?? []).filter { $0.parent == task.id && !$0.isCompleted } : []
        let affected = [task.id] + children.map(\.id)
        let now = ISO8601DateFormatter.nowString()
        change(listID) { items in
            for i in items.indices where affected.contains(items[i].id) {
                items[i].status = completed ? "completed" : "needsAction"
                items[i].completed = completed ? now : nil
            }
        }
        let fields: [String: Any] = completed ? ["status": "completed"] : ["status": "needsAction", "completed": NSNull()]
        enqueue(listID) { [self] in
            for id in affected {
                _ = try await api.patchTask(in: resolve(listID), id: resolve(id), fields: fields)
            }
        }
    }

    func rename(_ task: TaskItem, to title: String, in listID: String) {
        guard title != (task.title ?? "") else { return }
        update(task, in: listID, fields: ["title": title]) { $0.title = title }
    }

    func setNotes(_ task: TaskItem, _ notes: String, in listID: String) {
        guard notes != (task.notes ?? "") else { return }
        update(task, in: listID, fields: ["notes": notes.isEmpty ? NSNull() : notes]) { $0.notes = notes.isEmpty ? nil : notes }
    }

    func setDue(_ task: TaskItem, _ date: Date?, in listID: String) {
        let due = date.map(TaskItem.dueString)
        guard due != task.due else { return }
        update(task, in: listID, fields: ["due": due ?? NSNull()]) { $0.due = due }
    }

    private func update(_ task: TaskItem, in listID: String, fields: [String: Any], _ apply: @escaping (inout TaskItem) -> Void) {
        change(listID) { items in
            if let i = items.firstIndex(where: { $0.id == task.id }) { apply(&items[i]) }
        }
        enqueue(listID) { [self] in
            _ = try await api.patchTask(in: resolve(listID), id: resolve(task.id), fields: fields)
        }
    }

    func delete(_ task: TaskItem, in listID: String) {
        let children = (tasks[listID] ?? []).filter { $0.parent == task.id }.map(\.id)
        change(listID) { $0.removeAll { $0.id == task.id || children.contains($0.id) } }
        enqueue(listID) { [self] in
            for id in children + [task.id] { try await api.deleteTask(in: resolve(listID), id: resolve(id)) }
        }
    }

    func deleteCompleted() {
        guard let listID = selectedListID else { return }
        let ids = completedTasks(in: listID).map(\.id)
        guard !ids.isEmpty else { return }
        change(listID) { $0.removeAll { ids.contains($0.id) } }
        enqueue(listID) { [self] in
            for id in ids { try await api.deleteTask(in: resolve(listID), id: resolve(id)) }
        }
        messages.send(ids.count == 1 ? "Deleted 1 completed task" : "Deleted \(ids.count) completed tasks")
    }

    // MARK: Moving

    /// Drag and drop in the open list. Top-level tasks move among top-level tasks (their subtasks come
    /// along); a subtask lands under the task above the drop point.
    func move(from source: IndexSet, to destination: Int) {
        guard let listID = selectedListID, let from = source.first else { return }
        let rows = openRows(in: listID)
        guard rows.indices.contains(from) else { return }
        let moving = rows[from]
        // Rows above the drop point, without the moved task (and its subtasks).
        let above = rows.prefix(destination).filter { $0.id != moving.id && $0.task.parent != moving.id }

        if moving.depth == 0 || above.isEmpty {
            let previous = above.last.map { $0.depth == 0 ? $0.task : topLevelAncestor(of: $0.task, rows: rows) }
            guard moving.depth != 0 || previous?.id != topLevelBefore(moving.task, rows: rows)?.id else { return }
            place(moving.task, parent: nil, after: previous, in: listID)
        } else {
            let target = above.last!
            if target.depth == 0 {
                guard !(target.task.id == moving.task.parent && isFirstChild(moving.task, rows: rows)) else { return }
                place(moving.task, parent: target.task, after: nil, in: listID)
            } else {
                guard target.task.id != previousSibling(of: moving.task, rows: rows)?.id else { return }
                let parent = rows.first { $0.id == target.task.parent }?.task
                place(moving.task, parent: parent, after: target.task, in: listID)
            }
        }
    }

    func canIndent(_ task: TaskItem) -> Bool {
        guard let listID = selectedListID, task.parent == nil else { return false }
        return !hasChildren(task, in: listID) && topLevelBefore(task, rows: openRows(in: listID)) != nil
    }

    /// Makes the task a subtask of the task above it.
    func indent(_ task: TaskItem) {
        guard let listID = selectedListID, canIndent(task) else { return }
        let rows = openRows(in: listID)
        guard let parent = topLevelBefore(task, rows: rows) else { return }
        let lastChild = rows.last { $0.task.parent == parent.id }?.task
        place(task, parent: parent, after: lastChild, in: listID)
    }

    /// Lifts a subtask to the top level, right after its parent.
    func outdent(_ task: TaskItem) {
        guard let listID = selectedListID, let parentID = task.parent,
              let parent = (tasks[listID] ?? []).first(where: { $0.id == parentID }) else { return }
        place(task, parent: nil, after: parent, in: listID)
    }

    func moveToList(_ task: TaskItem, from listID: String, to destination: String) {
        guard destination != listID else { return }
        let children = (tasks[listID] ?? []).filter { $0.parent == task.id }
        change(listID) { $0.removeAll { $0.id == task.id || $0.parent == task.id } }
        if loadedLists.contains(destination) {
            change(destination) { items in
                var moved = task
                moved.parent = nil
                moved.position = ""
                items.insert(moved, at: 0)
                items += children
            }
        }
        touchedLists.insert(destination)
        enqueue(listID) { [self] in
            let dest = resolve(destination)
            let moved = try await api.moveTask(in: resolve(listID), id: resolve(task.id), parent: nil, previous: nil, toList: dest)
            var previous: String?
            for child in children {
                let c = try await api.moveTask(in: resolve(listID), id: resolve(child.id), parent: moved.id,
                                               previous: previous, toList: dest)
                previous = c.id
            }
        }
        let name = lists.first { $0.id == destination }?.title ?? "list"
        messages.send("Moved to \(name)")
    }

    private func place(_ task: TaskItem, parent: TaskItem?, after previous: TaskItem?, in listID: String) {
        // Mirror the new order locally by renumbering the new siblings; the server assigns real positions.
        let rows = openRows(in: listID)
        var siblings = rows.map(\.task).filter { $0.parent == parent?.id && $0.id != task.id }
        if parent == nil {
            siblings = rows.filter { $0.depth == 0 && $0.id != task.id }.map(\.task)
        }
        let insertAt = previous.flatMap { p in siblings.firstIndex { $0.id == p.id }.map { $0 + 1 } } ?? 0
        siblings.insert(task, at: insertAt)
        let positions = Dictionary(uniqueKeysWithValues: siblings.enumerated().map { ($1.id, String(format: "%020d", $0 * 1000)) })
        change(listID) { items in
            for i in items.indices {
                if items[i].id == task.id { items[i].parent = parent?.id }
                if let p = positions[items[i].id] { items[i].position = p }
            }
        }
        enqueue(listID) { [self] in
            _ = try await api.moveTask(in: resolve(listID), id: resolve(task.id), parent: parent.map { resolve($0.id) },
                                       previous: previous.map { resolve($0.id) })
        }
    }

    private func topLevelAncestor(of task: TaskItem, rows: [Row]) -> TaskItem {
        rows.first { $0.id == task.parent && $0.depth == 0 }?.task ?? task
    }

    private func topLevelBefore(_ task: TaskItem, rows: [Row]) -> TaskItem? {
        let tops = rows.filter { $0.depth == 0 }
        guard let i = tops.firstIndex(where: { $0.id == task.id }), i > 0 else { return nil }
        return tops[i - 1].task
    }

    private func previousSibling(of task: TaskItem, rows: [Row]) -> TaskItem? {
        let siblings = rows.filter { $0.task.parent == task.parent && $0.depth == 1 }
        guard let i = siblings.firstIndex(where: { $0.id == task.id }), i > 0 else { return nil }
        return siblings[i - 1].task
    }

    private func isFirstChild(_ task: TaskItem, rows: [Row]) -> Bool {
        rows.first { $0.task.parent == task.parent && $0.depth == 1 }?.id == task.id
    }

    // MARK: List edits

    func createList(title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let localID = "local-" + UUID().uuidString
        lists.append(TaskList(id: localID, title: title))
        tasks[localID] = []
        loadedLists.insert(localID)
        select(listID: localID)
        editGeneration += 1
        enqueue(nil) { [self] in
            let created = try await api.createList(title: title)
            aliases[localID] = created.id
        }
    }

    func renameList(_ list: TaskList, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != list.title, let i = lists.firstIndex(where: { $0.id == list.id }) else { return }
        lists[i].title = title
        editGeneration += 1
        enqueue(nil) { [self] in try await api.renameList(resolve(list.id), title: title) }
    }

    func deleteList(_ list: TaskList) {
        guard lists.count > 1, let i = lists.firstIndex(where: { $0.id == list.id }) else {
            messages.send("Can’t delete the only list")
            return
        }
        lists.remove(at: i)
        tasks[list.id] = nil
        loadedLists.remove(list.id)
        if selectedListID == list.id {
            let neighbor = lists[max(0, i - 1)].id
            if showingToday { selectedListID = neighbor } else { select(listID: neighbor) }
        }
        editGeneration += 1
        enqueue(nil) { [self] in try await api.deleteList(resolve(list.id)) }
        messages.send("Deleted “\(list.title)”")
    }

    // MARK: Plumbing

    private func resolve(_ id: String) -> String { aliases[id] ?? id }

    private func change(_ listID: String, _ body: (inout [TaskItem]) -> Void) {
        var items = tasks[listID] ?? []
        body(&items)
        tasks[listID] = items
        editGeneration += 1
    }

    private func enqueue(_ listID: String?, _ op: @escaping @MainActor () async throws -> Void) {
        guard !isDemo else { return }
        pendingWrites += 1
        if let listID { touchedLists.insert(listID) }
        reconcileWork?.cancel()
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            do {
                try await op()
            } catch is CancellationError {
            } catch {
                self?.report(error)
            }
            guard let self else { return }
            self.pendingWrites -= 1
            if self.pendingWrites == 0 { self.scheduleReconcile() }
        }
        scheduleSave()
    }

    /// After the queue drains, take the server's word for everything touched.
    private func scheduleReconcile() {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingWrites == 0 else { return }
            // A failed write leaves the local copy wrong, so the selected list is always re-read too.
            var touched = self.touchedLists
            if let selected = self.selectedListID { touched.insert(selected) }
            self.touchedLists = []
            Task {
                do {
                    let generation = self.editGeneration
                    let fetched = try await self.api.lists()
                    if generation == self.editGeneration, self.pendingWrites == 0 {
                        // Lists created here now have real ids.
                        if let selected = self.selectedListID, let real = self.aliases[selected] { self.selectedListID = real }
                        self.lists = fetched
                    }
                    for id in Set(touched.map(self.resolve)) where id == self.selectedListID || self.loadedLists.contains(id) {
                        if !fetched.contains(where: { $0.id == id }) { continue }
                        try await self.reloadTasks(id)
                    }
                    for (local, _) in self.aliases where self.tasks[local] != nil { self.tasks[local] = nil }
                } catch {
                    self.report(error)
                }
                self.scheduleSave()
            }
        }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func report(_ error: Error) {
        if case AuthError.notSignedIn = error {
            messages.send("Signed out of Google — sign in again in Settings")
        } else if (error as? URLError)?.code == .notConnectedToInternet {
            messages.send("Offline — changes may not be saved")
        } else {
            messages.send(error.localizedDescription)
        }
    }

    // MARK: Demo

    func loadDemo() {
        isDemo = true
        let day = { (offset: Int) in TaskItem.dueString(for: Calendar.current.date(byAdding: .day, value: offset, to: Date())!) }
        func t(_ id: String, _ title: String, notes: String? = nil, due: String? = nil, parent: String? = nil,
               done: Bool = false, pos: Int) -> TaskItem {
            TaskItem(id: id, title: title, notes: notes, status: done ? "completed" : "needsAction", due: due,
                     completed: done ? ISO8601DateFormatter.nowString() : nil, parent: parent,
                     position: String(format: "%020d", pos))
        }
        lists = [TaskList(id: "inbox", title: "My Tasks"), TaskList(id: "work", title: "Work"),
                 TaskList(id: "home", title: "Home")]
        tasks = [
            "inbox": [
                t("1", "Book dentist appointment", due: day(-1), pos: 1),
                t("2", "Prepare slides for Thursday", notes: "Keep it to 10 slides. Reuse the Q3 charts.", due: day(0), pos: 2),
                t("2a", "Collect numbers from finance", parent: "2", pos: 1),
                t("2b", "Draft outline", parent: "2", pos: 2),
                t("3", "Renew passport", due: day(9), pos: 3),
                t("4", "Call mom", pos: 4),
                t("5", "Read “The Design of Everyday Things”", notes: "Chapter 3 next", pos: 5),
                t("6", "Pay electricity bill", done: true, pos: 6),
                t("7", "Water the plants", done: true, pos: 7),
            ],
            "work": [
                t("w1", "Send the contract to Acme", due: day(0), pos: 1),
                t("w2", "Review Ken’s pull request", due: day(-2), pos: 2),
                t("w3", "Weekly report", due: day(0), done: true, pos: 3),
            ],
            "home": [],
        ]
        selectedListID = "inbox"
    }

    // MARK: Cache

    /// The last synced state, so the panel shows tasks at once on launch (the server refresh follows).
    private struct Cache: Codable {
        var lists: [TaskList]
        var tasks: [String: [TaskItem]]
    }

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.tachibanayu24.Dueday", isDirectory: true)
            .appendingPathComponent("cache.json")
    }

    private func loadCache() {
        guard auth.isSignedIn, let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        lists = cache.lists.filter { !$0.id.hasPrefix("local-") }
        tasks = cache.tasks.mapValues { $0.filter { !$0.id.hasPrefix("local-") } }
        let saved = UserDefaults.standard.string(forKey: "selectedList")
        selectedListID = lists.contains { $0.id == saved } ? saved : lists.first?.id
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.auth.isSignedIn else { return }
            let cache = Cache(lists: self.lists, tasks: self.tasks)
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.cacheURL, options: [.atomic])
            // The cache holds task contents: keep it private to this user.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.cacheURL.path)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
