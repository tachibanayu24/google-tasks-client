import Combine
import Foundation
@testable import GoogleTasksClient

@MainActor
final class FakeAuth: AuthSession {
    let subject: CurrentValueSubject<Bool, Never>
    init(signedIn: Bool = true) { subject = CurrentValueSubject(signedIn) }
    var isSignedIn: Bool { subject.value }
    var signedInChanges: AnyPublisher<Bool, Never> { subject.eraseToAnyPublisher() }
}

struct FakeError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// An in-memory Google Tasks with the rules that matter to the store: one level of subtasks, completed
/// tasks can't be nested, positions come from sibling order, and a move doesn't carry subtasks along
/// (the documentation doesn't promise it does).
@MainActor
final class FakeTasks: TasksService {
    struct Stored {
        var task: TaskItem
        var list: String
    }

    private(set) var lists: [TaskList] = []
    private var tasks: [String: Stored] = [:]
    /// Sibling order per list and parent ("" = top level).
    private var order: [String: [String]] = [:]
    private var nextID = 0
    /// Names of calls that should fail next (each entry fails once).
    var failing: [String] = []
    private(set) var calls: [String] = []
    /// Reads answer late with what Google had when they were asked; writes take a while.
    var readDelay: Duration?
    var writeDelay: Duration?

    // MARK: Test helpers

    @discardableResult
    func seedList(_ title: String) -> String {
        let id = makeID("list")
        lists.append(TaskList(id: id, title: title))
        return id
    }

    @discardableResult
    func seedTask(_ title: String, in list: String, parent: String? = nil, due: String? = nil, completed: Bool = false) -> String {
        let id = makeID("task")
        var task = TaskItem(id: id, title: title, status: completed ? "completed" : "needsAction", due: due, parent: parent)
        if completed { task.completed = ISO8601DateFormatter.nowString() }
        tasks[id] = Stored(task: task, list: list)
        order[key(list, parent), default: []].append(id)
        return id
    }

    /// Titles in the order Google would show them, subtasks indented by two spaces.
    func outline(_ list: String) -> [String] {
        (order[key(list, nil)] ?? []).flatMap { id -> [String] in
            let t = tasks[id]!.task
            let children = (order[key(list, id)] ?? []).map { "  " + (tasks[$0]!.task.title ?? "") }
            return [(t.title ?? "") + (t.isCompleted ? " ✓" : "")] + children
        }
    }

    func task(titled title: String) -> TaskItem? {
        tasks.values.first { $0.task.title == title }.map { materialize($0.task.id) }
    }

    func listOf(_ title: String) -> String? {
        tasks.values.first { $0.task.title == title }?.list
    }

    // MARK: TasksService

    func lists() async throws -> [TaskList] {
        try check("lists")
        let snapshot = lists
        if let readDelay { try await Task.sleep(for: readDelay) }
        return snapshot
    }

    func createList(title: String) async throws -> TaskList {
        try check("createList")
        if let writeDelay { try await Task.sleep(for: writeDelay) }
        let list = TaskList(id: makeID("list"), title: title)
        lists.append(list)
        return list
    }

    func renameList(_ id: String, title: String) async throws {
        try check("renameList")
        guard let i = lists.firstIndex(where: { $0.id == id }) else { throw FakeError(message: "404 list") }
        lists[i].title = title
    }

    func deleteList(_ id: String) async throws {
        try check("deleteList")
        guard lists.contains(where: { $0.id == id }) else { throw FakeError(message: "404 list") }
        lists.removeAll { $0.id == id }
        tasks = tasks.filter { $0.value.list != id }
    }

    func tasks(in list: String) async throws -> [TaskItem] {
        try check("tasks")
        guard lists.contains(where: { $0.id == list }) else { throw FakeError(message: "404 list") }
        let snapshot = tasks.values.filter { $0.list == list }.map { materialize($0.task.id) }
        if let readDelay { try await Task.sleep(for: readDelay) }
        return snapshot
    }

    func insertTask(in list: String, fields: [String: Any], parent: String?, previous: String?) async throws -> TaskItem {
        try check("insertTask")
        if let writeDelay { try await Task.sleep(for: writeDelay) }
        guard lists.contains(where: { $0.id == list }) else { throw FakeError(message: "404 list") }
        if let parent { try validateParent(parent, in: list) }
        let id = makeID("task")
        var task = TaskItem(id: id, status: "needsAction", parent: parent)
        apply(fields, to: &task)
        tasks[id] = Stored(task: task, list: list)
        try insert(id, in: list, parent: parent, after: previous)
        return materialize(id)
    }

    func patchTask(in list: String, id: String, fields: [String: Any]) async throws -> TaskItem {
        try check("patchTask")
        guard var stored = tasks[id], stored.list == list else { throw FakeError(message: "404 task") }
        apply(fields, to: &stored.task)
        tasks[id] = stored
        return materialize(id)
    }

    func deleteTask(in list: String, id: String) async throws {
        try check("deleteTask")
        guard let stored = tasks[id], stored.list == list else { throw FakeError(message: "404 task") }
        tasks[id] = nil
        order[key(list, stored.task.parent)]?.removeAll { $0 == id }
    }

    func moveTask(in list: String, id: String, parent: String?, previous: String?, toList: String?) async throws -> TaskItem {
        try check("moveTask")
        guard var stored = tasks[id], stored.list == list else { throw FakeError(message: "404 task") }
        let target = toList ?? list
        if let parent {
            try validateParent(parent, in: target)
            guard !stored.task.isCompleted else { throw FakeError(message: "completed tasks can't be nested") }
            guard !(order[key(list, id)] ?? []).contains(where: { tasks[$0] != nil }) else {
                throw FakeError(message: "a task with subtasks can't become a subtask")
            }
        }
        order[key(list, stored.task.parent)]?.removeAll { $0 == id }
        stored.task.parent = parent
        stored.list = target
        tasks[id] = stored
        try insert(id, in: target, parent: parent, after: previous)
        return materialize(id)
    }

    // MARK: Internals

    private func check(_ name: String) throws {
        calls.append(name)
        if let i = failing.firstIndex(of: name) {
            failing.remove(at: i)
            throw FakeError(message: "\(name) failed")
        }
    }

    private func makeID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)\(nextID)"
    }

    private func key(_ list: String, _ parent: String?) -> String { list + "/" + (parent ?? "") }

    private func validateParent(_ parent: String, in list: String) throws {
        guard let p = tasks[parent], p.list == list else { throw FakeError(message: "404 parent") }
        guard p.task.parent == nil else { throw FakeError(message: "subtasks can't have subtasks") }
    }

    private func insert(_ id: String, in list: String, parent: String?, after previous: String?) throws {
        var siblings = order[key(list, parent), default: []]
        if let previous {
            guard let i = siblings.firstIndex(of: previous) else { throw FakeError(message: "previous is not a sibling") }
            siblings.insert(id, at: i + 1)
        } else {
            siblings.insert(id, at: 0)
        }
        order[key(list, parent)] = siblings
    }

    private func apply(_ fields: [String: Any], to task: inout TaskItem) {
        for (name, value) in fields {
            let string = value as? String
            switch name {
            case "title": task.title = string
            case "notes": task.notes = string
            case "due": task.due = string
            case "status":
                task.status = string
                if string == "completed", task.completed == nil { task.completed = ISO8601DateFormatter.nowString() }
            case "completed": task.completed = string
            default: break
            }
        }
    }

    private func materialize(_ id: String) -> TaskItem {
        let stored = tasks[id]!
        var task = stored.task
        let index = order[key(stored.list, task.parent)]?.firstIndex(of: id) ?? 0
        task.position = String(format: "%020d", index)
        return task
    }
}
