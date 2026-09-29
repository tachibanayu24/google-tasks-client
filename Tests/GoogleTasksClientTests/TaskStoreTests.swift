import Foundation
import Testing
@testable import GoogleTasksClient

@MainActor
@Suite struct TaskStoreTests {
    let google = FakeTasks()
    let auth = FakeAuth()
    let inbox: String
    let work: String

    init() {
        inbox = google.seedList("Inbox")
        work = google.seedList("Work")
    }

    func makeStore() async -> TaskStore {
        let defaults = UserDefaults(suiteName: "GoogleTasksClientTests-" + UUID().uuidString)!
        let store = TaskStore(auth: auth, api: google, defaults: defaults, cacheURL: nil, reconcileDelay: .zero)
        await store.refresh()
        store.select(listID: inbox)
        return store
    }

    func titles(_ store: TaskStore, _ list: String) -> [String] {
        store.openRows(in: list).map { String(repeating: "  ", count: $0.depth) + ($0.task.title ?? "") }
    }

    func row(_ store: TaskStore, _ title: String, in list: String? = nil) -> TaskItem {
        store.openRows(in: list ?? inbox).first { $0.task.title == title }!.task
    }

    // MARK: Adding and editing

    @Test func addedTaskGoesFirstAndReachesGoogle() async {
        google.seedTask("Old", in: inbox)
        let store = await makeStore()
        store.addTask(title: "  New  ")
        #expect(titles(store, inbox) == ["New", "Old"])
        await store.settle()
        #expect(google.outline(inbox) == ["New", "Old"])
        #expect(titles(store, inbox) == ["New", "Old"])
    }

    @Test func editsBeforeGoogleAnswersFollowTheNewTask() async {
        let store = await makeStore()
        store.addTask(title: "Draft")
        let local = row(store, "Draft")
        let rowID = store.rowID(local)
        store.rename(local, to: "Final", in: inbox)
        store.setNotes(local, "notes", in: inbox)
        store.setCompleted(local, true, in: inbox)
        await store.settle()
        let remote = google.task(titled: "Final")
        #expect(remote?.notes == "notes")
        #expect(remote?.isCompleted == true)
        // The row keeps its identity across the swap to Google's copy, so the UI doesn't rebuild it.
        let synced = store.completedTasks(in: inbox).first { $0.title == "Final" }!
        #expect(!synced.id.hasPrefix("local-"))
        #expect(store.rowID(synced) == rowID)
    }

    @Test func subtaskIsAddedLastUnderItsParent() async {
        let parent = google.seedTask("Parent", in: inbox)
        google.seedTask("First", in: inbox, parent: parent)
        let store = await makeStore()
        store.addTask(title: "Second", parent: row(store, "Parent"))
        #expect(titles(store, inbox) == ["Parent", "  First", "  Second"])
        await store.settle()
        #expect(google.outline(inbox) == ["Parent", "  First", "  Second"])
    }

    @Test func completingAParentCompletesItsOpenSubtasks() async {
        let parent = google.seedTask("Parent", in: inbox)
        google.seedTask("Child", in: inbox, parent: parent)
        let store = await makeStore()
        store.setCompleted(row(store, "Parent"), true, in: inbox)
        await store.settle()
        #expect(google.task(titled: "Parent")?.isCompleted == true)
        #expect(google.task(titled: "Child")?.isCompleted == true)
        #expect(store.openRows(in: inbox).isEmpty)
    }

    @Test func dueDatesAreSetAndCleared() async {
        google.seedTask("Pay rent", in: inbox)
        let store = await makeStore()
        let date = DateComponents(calendar: .current, year: 2026, month: 10, day: 3).date!
        store.setDue(row(store, "Pay rent"), date, in: inbox)
        await store.settle()
        #expect(google.task(titled: "Pay rent")?.due == "2026-10-03T00:00:00.000Z")
        store.setDue(row(store, "Pay rent"), nil, in: inbox)
        await store.settle()
        #expect(google.task(titled: "Pay rent")?.due == nil)
    }

    // MARK: Moving

    @Test func draggingReordersTopLevelTasksWithTheirSubtasks() async {
        let a = google.seedTask("A", in: inbox)
        google.seedTask("A1", in: inbox, parent: a)
        google.seedTask("B", in: inbox)
        google.seedTask("C", in: inbox)
        let store = await makeStore()
        // Rows: A, A1, B, C. Drag A to the end.
        store.move(from: [0], to: 4)
        #expect(titles(store, inbox) == ["B", "C", "A", "  A1"])
        await store.settle()
        #expect(google.outline(inbox) == ["B", "C", "A", "  A1"])
    }

    @Test func draggingASubtaskUnderAnotherTask() async {
        let a = google.seedTask("A", in: inbox)
        google.seedTask("A1", in: inbox, parent: a)
        google.seedTask("B", in: inbox)
        let store = await makeStore()
        // Rows: A, A1, B. Drop A1 below B: it becomes B's subtask.
        store.move(from: [1], to: 3)
        await store.settle()
        #expect(google.outline(inbox) == ["A", "B", "  A1"])
        #expect(titles(store, inbox) == ["A", "B", "  A1"])
    }

    @Test func draggingASubtaskToTheTopMakesItATask() async {
        let a = google.seedTask("A", in: inbox)
        google.seedTask("A1", in: inbox, parent: a)
        let store = await makeStore()
        store.move(from: [1], to: 0)
        await store.settle()
        #expect(google.outline(inbox) == ["A1", "A"])
    }

    @Test func droppingInPlaceSendsNothing() async {
        google.seedTask("A", in: inbox)
        google.seedTask("B", in: inbox)
        let store = await makeStore()
        store.move(from: [1], to: 2)
        store.move(from: [0], to: 1)
        await store.settle()
        #expect(!google.calls.contains("moveTask"))
    }

    @Test func indentAndOutdent() async {
        google.seedTask("A", in: inbox)
        google.seedTask("B", in: inbox)
        let store = await makeStore()
        #expect(!store.canIndent(row(store, "A")))
        #expect(store.canIndent(row(store, "B")))
        store.indent(row(store, "B"))
        await store.settle()
        #expect(google.outline(inbox) == ["A", "  B"])
        store.outdent(row(store, "B"))
        await store.settle()
        #expect(google.outline(inbox) == ["A", "B"])
    }

    @Test func aTaskWithOnlyCompletedSubtasksCantBeIndented() async {
        google.seedTask("A", in: inbox)
        let b = google.seedTask("B", in: inbox)
        google.seedTask("B1", in: inbox, parent: b, completed: true)
        let store = await makeStore()
        #expect(!store.canIndent(row(store, "B")))
    }

    @Test func movingToAnotherListBringsSubtasksAlong() async {
        let a = google.seedTask("A", in: inbox)
        google.seedTask("Open child", in: inbox, parent: a)
        google.seedTask("Done child", in: inbox, parent: a, completed: true)
        google.seedTask("Existing", in: work)
        let store = await makeStore()
        store.moveToList(row(store, "A"), from: inbox, to: work)
        #expect(store.openRows(in: inbox).isEmpty)
        await store.settle()
        #expect(google.listOf("A") == work)
        #expect(google.listOf("Open child") == work)
        #expect(google.listOf("Done child") == work)
        #expect(google.task(titled: "Open child")?.parent == google.task(titled: "A")?.id)
        // Completed tasks can't be nested; it arrives at the top level.
        #expect(google.task(titled: "Done child")?.parent == nil)
        #expect(titles(store, work).prefix(2) == ["A", "  Open child"])
    }

    @Test func orphanedSubtasksAreNeverUsedAsTopLevelNeighbours() async {
        let done = google.seedTask("Done parent", in: inbox, completed: true)
        google.seedTask("Orphan", in: inbox, parent: done)
        google.seedTask("B", in: inbox)
        let store = await makeStore()
        // The orphan (open subtask of a completed task) shows at the top level.
        #expect(titles(store, inbox) == ["Orphan", "B"])
        // B dropped below the orphan has no real top-level task above it: nothing to tell Google.
        store.move(from: [1], to: 2)
        await store.settle()
        #expect(!google.calls.contains("moveTask"))
        // The orphan dropped below B becomes a real top-level task after B.
        store.move(from: [0], to: 2)
        await store.settle()
        #expect(google.outline(inbox) == ["Done parent ✓", "B", "Orphan"])
        #expect(store.syncProblem == nil)
    }

    // MARK: Deleting

    @Test func deletingATaskDeletesItsSubtasks() async {
        let a = google.seedTask("A", in: inbox)
        google.seedTask("A1", in: inbox, parent: a)
        let store = await makeStore()
        store.delete(row(store, "A"), in: inbox)
        await store.settle()
        #expect(google.outline(inbox).isEmpty)
        #expect(google.task(titled: "A1") == nil)
    }

    @Test func deleteCompletedSparesParentsOfOpenSubtasks() async {
        google.seedTask("Done", in: inbox, completed: true)
        let parent = google.seedTask("Done parent", in: inbox, completed: true)
        google.seedTask("Still open", in: inbox, parent: parent)
        let store = await makeStore()
        store.deleteCompleted()
        await store.settle()
        #expect(google.task(titled: "Done") == nil)
        #expect(google.task(titled: "Done parent") != nil)
        #expect(google.task(titled: "Still open") != nil)
    }

    // MARK: Lists

    @Test func tasksAddedToANewListBeforeGoogleCreatesItLandInIt() async {
        let store = await makeStore()
        store.createList(title: "Groceries")
        let localID = store.selectedListID!
        store.addTask(title: "Milk")
        store.addTask(title: "Eggs", in: localID)
        await store.settle()
        let real = google.lists.first { $0.title == "Groceries" }!.id
        #expect(store.selectedListID == real)
        #expect(google.outline(real) == ["Eggs", "Milk"])
        #expect(titles(store, real) == ["Eggs", "Milk"])
        // Views may still hold the placeholder id; it keeps working.
        #expect(titles(store, localID) == ["Eggs", "Milk"])
    }

    @Test func renameAndDeleteList() async {
        let store = await makeStore()
        store.renameList(store.lists.first { $0.id == work }!, to: "Office")
        await store.settle()
        #expect(google.lists.first { $0.id == work }?.title == "Office")
        store.deleteList(store.lists.first { $0.id == work }!)
        await store.settle()
        #expect(!google.lists.contains { $0.id == work })
        #expect(!store.lists.contains { $0.id == work })
    }

    @Test func subtasksCantBeAddedUnderSubtasks() async {
        let done = google.seedTask("Done parent", in: inbox, completed: true)
        google.seedTask("Orphan", in: inbox, parent: done)
        let store = await makeStore()
        store.addTask(title: "Nested", parent: row(store, "Orphan"))
        await store.settle()
        #expect(google.task(titled: "Nested") == nil)
        #expect(!google.calls.contains("insertTask"))
    }

    @Test func aNewListStaysSelectedAcrossRelaunch() async {
        let defaults = UserDefaults(suiteName: "GoogleTasksClientTests-" + UUID().uuidString)!
        let store = TaskStore(auth: auth, api: google, defaults: defaults, cacheURL: nil, reconcileDelay: .zero)
        await store.refresh()
        store.createList(title: "Groceries")
        await store.settle()
        #expect(defaults.string(forKey: "selectedList") == google.lists.first { $0.title == "Groceries" }?.id)
    }

    // MARK: Races

    @Test func aPollOverlappingACreateDoesntUndoIt() async throws {
        let store = await makeStore()
        google.readDelay = .milliseconds(80)
        google.writeDelay = .milliseconds(20)
        store.createList(title: "Groceries")
        // The poll starts while the create is on its way and answers with what Google had before it.
        await store.refresh()
        #expect(store.selectedList?.title == "Groceries")
        store.addTask(title: "Milk")
        await store.settle()
        let groceries = google.lists.first { $0.title == "Groceries" }!.id
        #expect(google.outline(groceries) == ["Milk"])
        #expect(google.outline(inbox).isEmpty)
    }

    @Test func aPollOverlappingAnAddDoesntHideTheTask() async throws {
        let store = await makeStore()
        // The task list is read while the insert is still on its way, and lands after it finished.
        google.readDelay = .milliseconds(80)
        google.writeDelay = .milliseconds(150)
        store.addTask(title: "Fresh")
        await store.refresh()
        #expect(titles(store, inbox) == ["Fresh"])
        await store.settle()
        #expect(titles(store, inbox) == ["Fresh"])
    }

    // MARK: Failures

    @Test func aFailedChildCreateDoesntStopCompletingTheRest() async {
        let parent = google.seedTask("Parent", in: inbox)
        google.seedTask("Real child", in: inbox, parent: parent)
        let store = await makeStore()
        google.failing = ["insertTask"]
        store.addTask(title: "Ghost child", parent: row(store, "Parent"))
        store.setCompleted(row(store, "Parent"), true, in: inbox)
        await store.settle()
        #expect(google.task(titled: "Parent")?.isCompleted == true)
        #expect(google.task(titled: "Real child")?.isCompleted == true)
    }

    @Test func aFailedCreateDropsItsFollowUpsWithOneMessage() async {
        let store = await makeStore()
        var messages: [String] = []
        let sub = store.messages.sink { messages.append($0) }
        google.failing = ["insertTask"]
        store.addTask(title: "Lost")
        let local = row(store, "Lost")
        store.rename(local, to: "Still lost", in: inbox)
        store.setCompleted(local, true, in: inbox)
        await store.settle()
        sub.cancel()
        #expect(messages == ["insertTask failed"])
        #expect(!google.calls.contains("patchTask"))
        // The reconcile put the list back to what Google has.
        #expect(store.openRows(in: inbox).isEmpty)
    }

    @Test func failedWritesAreRolledBackToGoogleState() async {
        google.seedTask("Keep", in: inbox)
        let store = await makeStore()
        google.failing = ["deleteTask"]
        store.delete(row(store, "Keep"), in: inbox)
        #expect(store.openRows(in: inbox).isEmpty)
        await store.settle()
        #expect(titles(store, inbox) == ["Keep"])
    }

    @Test func signingOutDropsWorkForThePreviousAccount() async {
        google.seedTask("Mine", in: inbox)
        let store = await makeStore()
        store.rename(row(store, "Mine"), to: "Renamed", in: inbox)
        auth.subject.send(false)
        await store.settle()
        #expect(store.lists.isEmpty)
        #expect(store.tasks.isEmpty)
        #expect(google.task(titled: "Mine") != nil)
    }

    @Test func aSyncFailureIsReportedOnceUntilItRecovers() async {
        let store = await makeStore()
        var messages: [String] = []
        let sub = store.messages.sink { messages.append($0) }
        google.failing = ["lists", "lists"]
        await store.refresh()
        await store.refresh()
        #expect(messages.count == 1)
        #expect(store.syncProblem != nil)
        await store.refresh()
        #expect(store.syncProblem == nil)
        sub.cancel()
    }
}
