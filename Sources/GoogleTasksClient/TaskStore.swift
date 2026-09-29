import Combine
import Foundation

/// What the store needs to know about the Google session.
@MainActor
protocol AuthSession: AnyObject {
    var isSignedIn: Bool { get }
    var signedInChanges: AnyPublisher<Bool, Never> { get }
}

extension GoogleAuth: AuthSession {
    var signedInChanges: AnyPublisher<Bool, Never> { $isSignedIn.eraseToAnyPublisher() }
}

/// Local mirror of the user's Google Tasks. Every edit is applied here first (so the UI never waits on the
/// network) and then sent to Google through one serial queue, so edits reach the server in the order made.
/// Once the queue drains, the touched lists are re-read: the server's order and ids become the truth again.
@MainActor
final class TaskStore: ObservableObject {
    struct Row: Identifiable, Equatable {
        let task: TaskItem
        let depth: Int
        /// Stable across the swap from a locally created task to Google's copy of it.
        let id: String
    }

    struct Entry: Identifiable, Equatable {
        let listID: String
        let task: TaskItem
        let id: String
    }

    struct Today: Equatable {
        var overdue: [Entry] = []
        var dueToday: [Entry] = []
        /// Tasks due by today that were completed today.
        var done: [Entry] = []
        var remaining: Int { overdue.count + dueToday.count }
        var progress: Double { done.isEmpty ? 0 : Double(done.count) / Double(done.count + remaining) }
        var allDone: Bool { remaining == 0 && !done.isEmpty }
    }

    @Published private(set) var lists: [TaskList] = []
    @Published private(set) var selectedListID: String?
    /// The "Today" tab (due today or overdue, across all lists) instead of a single list.
    @Published private(set) var showingToday: Bool
    @Published private(set) var tasks: [String: [TaskItem]] = [:]
    @Published private(set) var isSyncing = false
    /// Set while Google can't be reached or refuses a sync; cleared by the next successful one.
    @Published private(set) var syncProblem: String?
    /// Row id of the task whose inline "new subtask" field is open.
    @Published var addingSubtaskTo: String?
    /// Whether the panel is on screen (set by the panel; views reset transient state when it closes).
    @Published var isPanelOpen = false
    /// Dev builds only: sample data, edits stay local.
    @Published private(set) var isDemo = false

    /// Short messages for the toast.
    let messages = PassthroughSubject<String, Never>()
    /// Asks the view to put the cursor in the "Add a task" field.
    let focusAddField = PassthroughSubject<Void, Never>()

    private let auth: AuthSession
    private let api: TasksService
    private let defaults: UserDefaults
    private let cacheURL: URL?

    /// Bumped on sign-out: work that started for the previous account is dropped when it lands.
    private var session = 0
    private var writeChain: Task<Void, Never>?
    private var pendingWrites = 0
    private var failedWrites: [Error] = []
    /// Bumped by every local change: a fetch that started before one is stale and gets dropped.
    private var editGeneration = 0
    /// Bumped whenever a write finishes: a fetch that overlapped one may predate it, so it's dropped too.
    private var finishedWrites = 0
    /// Local placeholder id → id Google assigned (tasks and lists created here).
    private var aliases: [String: String] = [:]
    /// Google's id → the placeholder the UI has known the task by.
    private var rowIDs: [String: String] = [:]
    private var touchedLists = Set<String>()
    private var reconcileTask: Task<Void, Never>?
    private let reconcileDelay: Duration
    private var saveWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(auth: AuthSession, api: TasksService, defaults: UserDefaults = .standard, cacheURL: URL? = TaskStore.defaultCacheURL,
         reconcileDelay: Duration = .milliseconds(800)) {
        self.auth = auth
        self.api = api
        self.defaults = defaults
        self.cacheURL = cacheURL
        self.reconcileDelay = reconcileDelay
        showingToday = defaults.object(forKey: "showingToday") as? Bool ?? true
        loadCache()
        auth.signedInChanges
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

    func listTitle(_ id: String) -> String { lists.first { $0.id == key(id) }?.title ?? "" }

    func rowID(_ task: TaskItem) -> String { rowIDs[task.id] ?? task.id }

    /// Open tasks in display order: each top-level task followed by its open subtasks.
    func openRows(in listID: String) -> [Row] {
        let open = (tasks[key(listID)] ?? []).enumerated().filter { !$0.element.isCompleted }
        let ids = Set(open.map(\.element.id))
        func sorted(_ items: [(offset: Int, element: TaskItem)]) -> [TaskItem] {
            items.sorted { a, b in
                let pa = a.element.position ?? "", pb = b.element.position ?? ""
                return pa == pb ? a.offset < b.offset : pa < pb
            }
            .map(\.element)
        }
        // A subtask whose parent is completed shows at the top level ("orphan") instead of disappearing.
        let tops = sorted(open.filter { $0.element.parent.map { !ids.contains($0) } ?? true })
        let children = Dictionary(grouping: open.filter { $0.element.parent.map(ids.contains) ?? false }) { $0.element.parent! }
        return tops.flatMap { top in
            [Row(task: top, depth: 0, id: rowID(top))]
                + sorted(children[top.id] ?? []).map { Row(task: $0, depth: 1, id: rowID($0)) }
        }
    }

    func completedTasks(in listID: String) -> [TaskItem] {
        (tasks[key(listID)] ?? []).filter(\.isCompleted).sorted { ($0.completed ?? "") > ($1.completed ?? "") }
    }

    /// What the menu bar counts: open tasks due today or earlier, in every list.
    var today: Today {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: start)!
        var result = Today()
        for list in lists {
            for task in tasks[list.id] ?? [] {
                guard let due = task.dueDate, due < tomorrow else { continue }
                let entry = Entry(listID: list.id, task: task, id: rowID(task))
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

    // MARK: Sync

    /// Re-reads every list (the menu bar counts across all of them).
    func refresh() async {
        guard !isDemo, auth.isSignedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let started = session
        do {
            let stamp = freshnessStamp()
            let fetched = try await api.lists()
            guard session == started else { return }
            if isFresh(stamp) {
                applyLists(fetched)
            }
            for list in lists where !list.id.hasPrefix("local-") {
                try await reloadTasks(list.id)
            }
            syncProblem = nil
            scheduleSave()
        } catch {
            guard session == started else { return }
            reportSyncFailure(error)
        }
    }

    private func applyLists(_ fetched: [TaskList]) {
        lists = fetched
        for id in tasks.keys where !fetched.contains(where: { $0.id == id }) { tasks[id] = nil }
        if selectedListID.map({ id in !lists.contains { $0.id == id } }) ?? true {
            selectedListID = lists.first?.id
        }
    }

    /// Replaces a list's tasks with Google's, unless a local edit happened meanwhile (then the list is left
    /// for the reconcile that follows the write queue).
    private func reloadTasks(_ listID: String) async throws {
        let started = session
        let stamp = freshnessStamp()
        let fetched = try await api.tasks(in: listID)
        guard session == started else { return }
        guard isFresh(stamp) else {
            touchedLists.insert(listID)
            return
        }
        tasks[listID] = fetched.filter { $0.deleted != true }
    }

    func select(listID: String) {
        let listID = key(listID)
        guard lists.contains(where: { $0.id == listID }) else { return }
        addingSubtaskTo = nil
        selectedListID = listID
        setShowingToday(false)
        defaults.set(listID, forKey: "selectedList")
    }

    func selectToday() {
        addingSubtaskTo = nil
        setShowingToday(true)
    }

    private func setShowingToday(_ value: Bool) {
        showingToday = value
        defaults.set(value, forKey: "showingToday")
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
        session += 1
        writeChain?.cancel()
        reconcileTask?.cancel()
        reconcileTask = nil
        lists = []
        tasks = [:]
        selectedListID = nil
        aliases = [:]
        rowIDs = [:]
        touchedLists = []
        failedWrites = []
        syncProblem = nil
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
    }

    // MARK: Task edits

    /// Adds to `listID` (default: the selected list). New top-level tasks go first, as in Google Tasks;
    /// new subtasks go last under their parent.
    func addTask(title: String, parent: TaskItem? = nil, in listID: String? = nil, dueToday: Bool = false) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let listID = (listID ?? selectedListID ?? lists.first?.id).map(key) else { return }
        let parent = parent.map { current($0, in: listID) }
        // One level of subtasks only.
        guard parent?.parent == nil else { return }
        let due = dueToday ? TaskItem.dueString(for: Date()) : nil
        let previous = parent.flatMap { p in openRows(in: listID).last { $0.task.parent == p.id }?.task }
        let localID = "local-" + UUID().uuidString
        var item = TaskItem(id: localID, title: title, status: "needsAction", due: due, parent: parent?.id)
        item.position = parent == nil ? "" : "~"
        change(listID) { $0.insert(item, at: 0) }
        var fields: [String: Any] = ["title": title]
        if let due { fields["due"] = due }
        enqueue(listID) { [self] in
            let created = try await api.insertTask(in: remote(listID), fields: fields,
                                                   parent: try parent.map { try remote($0.id) },
                                                   previous: try previous.map { try remote($0.id) })
            aliases[localID] = created.id
            rowIDs[created.id] = localID
        }
    }

    func setCompleted(_ task: TaskItem, _ completed: Bool, in listID: String) {
        let listID = key(listID)
        let task = current(task, in: listID)
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
            let list = try remote(listID)
            for id in affected {
                guard let id = try? remote(id) else { continue }
                _ = try await api.patchTask(in: list, id: id, fields: fields)
            }
        }
    }

    func rename(_ task: TaskItem, to title: String, in listID: String) {
        let task = current(task, in: key(listID))
        guard title != (task.title ?? "") else { return }
        update(task, in: listID, fields: ["title": title]) { $0.title = title }
    }

    func setNotes(_ task: TaskItem, _ notes: String, in listID: String) {
        let task = current(task, in: key(listID))
        guard notes != (task.notes ?? "") else { return }
        update(task, in: listID, fields: ["notes": notes.isEmpty ? NSNull() : notes]) { $0.notes = notes.isEmpty ? nil : notes }
    }

    func setDue(_ task: TaskItem, _ date: Date?, in listID: String) {
        let task = current(task, in: key(listID))
        let due = date.map(TaskItem.dueString)
        guard due != task.due else { return }
        update(task, in: listID, fields: ["due": due ?? NSNull()]) { $0.due = due }
    }

    private func update(_ task: TaskItem, in listID: String, fields: [String: Any], _ apply: @escaping (inout TaskItem) -> Void) {
        let listID = key(listID)
        change(listID) { items in
            if let i = items.firstIndex(where: { $0.id == task.id }) { apply(&items[i]) }
        }
        enqueue(listID) { [self] in
            _ = try await api.patchTask(in: remote(listID), id: remote(task.id), fields: fields)
        }
    }

    func delete(_ task: TaskItem, in listID: String) {
        let listID = key(listID)
        let task = current(task, in: listID)
        let children = (tasks[listID] ?? []).filter { $0.parent == task.id }.map(\.id)
        change(listID) { $0.removeAll { $0.id == task.id || children.contains($0.id) } }
        enqueue(listID) { [self] in
            let list = try remote(listID)
            for id in children + [task.id] {
                guard let id = try? remote(id) else { continue }
                try await api.deleteTask(in: list, id: id)
            }
        }
    }

    /// Deletes the selected list's completed tasks — except completed parents that still have open subtasks,
    /// which Google could take down with them.
    func deleteCompleted() {
        guard let listID = selectedListID else { return }
        let items = tasks[listID] ?? []
        let ids = items.filter { task in
            task.isCompleted && !items.contains { $0.parent == task.id && !$0.isCompleted }
        }.map(\.id)
        guard !ids.isEmpty else { return }
        change(listID) { $0.removeAll { ids.contains($0.id) } }
        enqueue(listID) { [self] in
            let list = try remote(listID)
            for id in ids {
                guard let id = try? remote(id) else { continue }
                try await api.deleteTask(in: list, id: id)
            }
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
        let above = rows.prefix(destination).filter { $0.task.id != moving.task.id && $0.task.parent != moving.task.id }
        let nestUnder = above.last.flatMap { target -> TaskItem? in
            guard moving.depth == 1 else { return nil }
            if target.depth == 1 { return rows.first { $0.task.id == target.task.parent }?.task }
            return target.task.parent == nil ? target.task : nil
        }

        if let parent = nestUnder {
            let previous = above.last.flatMap { $0.depth == 1 ? $0.task : nil }
            let current = previousSibling(of: moving.task, rows: rows)
            guard parent.id != moving.task.parent || previous?.id != current?.id else { return }
            place(moving.task, parent: parent, after: previous, in: listID)
        } else {
            // Among top-level tasks, only real ones can be `previous` (not subtasks shown at the top level
            // because their parent is completed).
            let previous = above.reversed().lazy.compactMap { row -> TaskItem? in
                if row.depth == 1 { return rows.first { $0.task.id == row.task.parent }?.task }
                return row.task.parent == nil ? row.task : nil
            }.first
            if moving.task.parent == nil, previous?.id == topLevelBefore(moving.task, rows: rows)?.id { return }
            place(moving.task, parent: nil, after: previous, in: listID)
        }
    }

    func canIndent(_ task: TaskItem) -> Bool {
        guard let listID = selectedListID else { return false }
        let task = current(task, in: listID)
        // Only one level of nesting: a task with any subtasks (open or done) can't become one.
        guard task.parent == nil, !(tasks[listID] ?? []).contains(where: { $0.parent == task.id }) else { return false }
        return topLevelBefore(task, rows: openRows(in: listID)) != nil
    }

    /// Makes the task a subtask of the task above it.
    func indent(_ task: TaskItem) {
        guard let listID = selectedListID, canIndent(task) else { return }
        let task = current(task, in: listID)
        let rows = openRows(in: listID)
        guard let parent = topLevelBefore(task, rows: rows) else { return }
        let lastChild = rows.last { $0.task.parent == parent.id }?.task
        place(task, parent: parent, after: lastChild, in: listID)
    }

    /// Lifts a subtask to the top level, right after its parent.
    func outdent(_ task: TaskItem) {
        guard let listID = selectedListID else { return }
        let task = current(task, in: listID)
        guard let parentID = task.parent, let parent = (tasks[listID] ?? []).first(where: { $0.id == parentID }) else { return }
        // A completed parent isn't among the open rows; place it after the nearest real top-level task instead.
        let rows = openRows(in: listID)
        let after = rows.contains { $0.task.id == parent.id } ? parent : topLevelBefore(task, rows: rows)
        place(task, parent: nil, after: after, in: listID)
    }

    /// Moves a task (and its subtasks) to the top of another list.
    func moveToList(_ task: TaskItem, from listID: String, to destination: String) {
        let listID = key(listID), destination = key(destination)
        guard destination != listID else { return }
        let task = current(task, in: listID)
        let children = (tasks[listID] ?? []).filter { $0.parent == task.id }
            .sorted { ($0.position ?? "") < ($1.position ?? "") }
        change(listID) { $0.removeAll { $0.id == task.id || $0.parent == task.id } }
        change(destination) { items in
            var moved = task
            moved.parent = nil
            moved.position = ""
            // Completed tasks can't be nested at Google; they arrive at the top level.
            items.insert(moved, at: 0)
            items += children.map { child in
                var c = child
                if c.isCompleted { c.parent = nil }
                return c
            }
        }
        touchedLists.insert(destination)
        enqueue(listID) { [self] in
            let source = try remote(listID), dest = try remote(destination)
            let moved = try await api.moveTask(in: source, id: remote(task.id), parent: nil, previous: nil, toList: dest)
            // Whether Google carries subtasks along isn't documented: move whichever are still behind.
            let left = Set(try await api.tasks(in: source).map(\.id))
            var previous: String?
            var failure: Error?
            for child in children {
                guard let id = try? remote(child.id), left.contains(id) else { continue }
                do {
                    if child.isCompleted {
                        _ = try await api.moveTask(in: source, id: id, parent: nil, previous: nil, toList: dest)
                    } else {
                        previous = try await api.moveTask(in: source, id: id, parent: moved.id, previous: previous, toList: dest).id
                    }
                } catch {
                    failure = failure ?? error
                }
            }
            if let failure { throw failure }
        }
        messages.send("Moved to \(listTitle(destination))")
    }

    private func place(_ task: TaskItem, parent: TaskItem?, after previous: TaskItem?, in listID: String) {
        // Mirror the new order locally by renumbering the new siblings; the server assigns real positions.
        let rows = openRows(in: listID)
        var siblings = parent == nil
            ? rows.filter { $0.depth == 0 && $0.task.parent == nil && $0.task.id != task.id }.map(\.task)
            : rows.map(\.task).filter { $0.parent == parent?.id && $0.id != task.id }
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
            _ = try await api.moveTask(in: remote(listID), id: remote(task.id), parent: try parent.map { try remote($0.id) },
                                       previous: try previous.map { try remote($0.id) }, toList: nil)
        }
    }

    /// The real top-level task above this one, if any.
    private func topLevelBefore(_ task: TaskItem, rows: [Row]) -> TaskItem? {
        guard let index = rows.firstIndex(where: { $0.task.id == task.id }) else { return nil }
        return rows[..<index].last { $0.depth == 0 && $0.task.parent == nil }?.task
    }

    private func previousSibling(of task: TaskItem, rows: [Row]) -> TaskItem? {
        let siblings = rows.filter { $0.task.parent == task.parent && $0.depth == 1 }
        guard let i = siblings.firstIndex(where: { $0.task.id == task.id }), i > 0 else { return nil }
        return siblings[i - 1].task
    }

    // MARK: List edits

    func createList(title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let localID = "local-" + UUID().uuidString
        lists.append(TaskList(id: localID, title: title))
        change(localID) { _ in }
        select(listID: localID)
        enqueue(nil) { [self] in
            let created = try await api.createList(title: title)
            adoptList(localID, as: created.id)
        }
    }

    /// Google created the list: switch everything over to its real id, so later edits and reloads use it.
    private func adoptList(_ localID: String, as realID: String) {
        aliases[localID] = realID
        if let i = lists.firstIndex(where: { $0.id == localID }) { lists[i].id = realID }
        tasks[realID] = tasks.removeValue(forKey: localID) ?? []
        if selectedListID == localID {
            selectedListID = realID
            defaults.set(realID, forKey: "selectedList")
        }
        if touchedLists.remove(localID) != nil { touchedLists.insert(realID) }
    }

    func renameList(_ list: TaskList, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = key(list.id)
        guard !title.isEmpty, let i = lists.firstIndex(where: { $0.id == id }), title != lists[i].title else { return }
        lists[i].title = title
        editGeneration += 1
        enqueue(nil) { [self] in try await api.renameList(remote(id), title: title) }
    }

    func deleteList(_ list: TaskList) {
        let id = key(list.id)
        guard lists.count > 1, let i = lists.firstIndex(where: { $0.id == id }) else {
            messages.send("Can’t delete the only list")
            return
        }
        lists.remove(at: i)
        tasks[id] = nil
        if selectedListID == id {
            let neighbor = lists[max(0, i - 1)].id
            if showingToday { selectedListID = neighbor } else { select(listID: neighbor) }
        }
        editGeneration += 1
        enqueue(nil) { [self] in try await api.deleteList(remote(id)) }
        messages.send("Deleted “\(list.title)”")
    }

    // MARK: Plumbing

    private struct FreshnessStamp: Equatable {
        var edits: Int
        var writes: Int
    }

    private func freshnessStamp() -> FreshnessStamp { FreshnessStamp(edits: editGeneration, writes: finishedWrites) }

    /// A fetch result can replace local state only if nothing was edited, written or still being written
    /// while it was on its way.
    private func isFresh(_ stamp: FreshnessStamp) -> Bool { stamp == freshnessStamp() && pendingWrites == 0 }

    /// Thrown for an edit whose task or list never made it to Google (its creation failed): nothing to send.
    private struct NotCreated: Error {}

    private func resolve(_ id: String) -> String { aliases[id] ?? id }

    /// The key a list is stored under right now (a list created here switches to its real id).
    private func key(_ listID: String) -> String { resolve(listID) }

    /// The id Google knows, for use inside queued writes.
    private func remote(_ id: String) throws -> String {
        let id = resolve(id)
        guard !id.hasPrefix("local-") else { throw NotCreated() }
        return id
    }

    /// The store's current copy of a task the UI handed back (it may still hold the placeholder version).
    private func current(_ task: TaskItem, in listID: String) -> TaskItem {
        let real = resolve(task.id)
        return tasks[listID]?.first { $0.id == task.id || $0.id == real } ?? task
    }

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
        reconcileTask?.cancel()
        reconcileTask = nil
        let previous = writeChain
        let started = session
        writeChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if self.session == started {
                do {
                    try await op()
                } catch {
                    if self.session == started, !Self.isSilent(error) { self.failedWrites.append(error) }
                }
            }
            self.finishedWrites += 1
            self.pendingWrites -= 1
            if self.pendingWrites == 0, self.session == started { self.writesDrained() }
        }
        scheduleSave()
    }

    private static func isSilent(_ error: Error) -> Bool {
        error is CancellationError || error is NotCreated || (error as? URLError)?.code == .cancelled
    }

    private func writesDrained() {
        if let first = failedWrites.first {
            // One message per burst: offline, ten queued edits would otherwise be ten toasts.
            let more = failedWrites.count - 1
            messages.send(Self.describe(first) + (more > 0 ? " (\(more + 1) changes not saved)" : ""))
            failedWrites = []
        }
        scheduleReconcile()
    }

    /// After the queue drains (and a short pause, in case more edits follow), take the server's word for
    /// everything touched.
    private func scheduleReconcile() {
        reconcileTask?.cancel()
        let delay = reconcileDelay
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.reconcile()
            if !Task.isCancelled { self.reconcileTask = nil }
        }
    }

    private func reconcile() async {
        guard pendingWrites == 0 else { return }
        // A failed write leaves the local copy wrong, so the selected list is always re-read too.
        var touched = touchedLists
        if let selected = selectedListID { touched.insert(selected) }
        touchedLists = []
        let started = session
        do {
            let stamp = freshnessStamp()
            let fetched = try await api.lists()
            guard session == started else { return }
            guard isFresh(stamp) else {
                // Edited meanwhile: that edit's own drain reconciles these too.
                touchedLists.formUnion(touched)
                return
            }
            applyLists(fetched)
            for id in Set(touched.map(resolve)) where fetched.contains(where: { $0.id == id }) {
                try await reloadTasks(id)
            }
            syncProblem = nil
        } catch {
            guard session == started else { return }
            touchedLists.formUnion(touched)
            reportSyncFailure(error)
        }
        scheduleSave()
    }

    /// Waits until every queued write has been sent and the reconcile after it has finished.
    func settle() async {
        while true {
            await writeChain?.value
            if let reconcileTask {
                await reconcileTask.value
            } else if pendingWrites == 0 {
                return
            }
        }
    }

    /// Background syncs fail quietly after the first time: the toast shows once, the problem stays visible
    /// in the panel until a sync succeeds.
    private func reportSyncFailure(_ error: Error) {
        guard !Self.isSilent(error) else { return }
        let message = Self.describe(error)
        if syncProblem != message { messages.send(message) }
        syncProblem = message
    }

    private static func describe(_ error: Error) -> String {
        if case AuthError.notSignedIn = error { return "Signed out of Google — click the menu bar icon to sign in" }
        if let code = (error as? URLError)?.code, [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                                   .cannotFindHost, .cannotConnectToHost].contains(code) {
            return "Can’t reach Google"
        }
        return error.localizedDescription
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

    /// The last synced state, so the count and the panel are right at launch (the server refresh follows).
    private struct Cache: Codable {
        var lists: [TaskList]
        var tasks: [String: [TaskItem]]
    }

    nonisolated static var defaultCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.tachibanayu24.GoogleTasksClient", isDirectory: true)
            .appendingPathComponent("cache.json")
    }

    private func loadCache() {
        guard auth.isSignedIn, let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        lists = cache.lists.filter { !$0.id.hasPrefix("local-") }
        tasks = cache.tasks.filter { !$0.key.hasPrefix("local-") }.mapValues { $0.filter { !$0.id.hasPrefix("local-") } }
        let saved = defaults.string(forKey: "selectedList")
        selectedListID = lists.contains { $0.id == saved } ? saved : lists.first?.id
    }

    private func scheduleSave() {
        guard let cacheURL else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.auth.isSignedIn, !self.isDemo else { return }
            let cache = Cache(lists: self.lists, tasks: self.tasks)
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: [.atomic])
            // The cache holds task contents: keep it private to this user.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
