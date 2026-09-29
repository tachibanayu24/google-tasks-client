import Foundation
import Testing
@testable import Dueday

@MainActor
@Suite struct TodayTests {
    let google = FakeTasks()
    let auth = FakeAuth()

    func day(_ offset: Int) -> String {
        TaskItem.dueString(for: Calendar.current.date(byAdding: .day, value: offset, to: Date())!)
    }

    func makeStore() async -> TaskStore {
        let defaults = UserDefaults(suiteName: "DuedayTests-" + UUID().uuidString)!
        let store = TaskStore(auth: auth, api: google, defaults: defaults, cacheURL: nil, reconcileDelay: .zero)
        await store.refresh()
        return store
    }

    @Test func countsOverdueAndTodayAcrossLists() async {
        let a = google.seedList("A")
        let b = google.seedList("B")
        google.seedTask("Late", in: a, due: day(-3))
        google.seedTask("Now", in: b, due: day(0))
        google.seedTask("Later", in: a, due: day(1))
        google.seedTask("Someday", in: b)
        let store = await makeStore()
        let today = store.today
        #expect(today.overdue.map(\.task.title) == ["Late"])
        #expect(today.dueToday.map(\.task.title) == ["Now"])
        #expect(today.remaining == 2)
        #expect(today.dueToday.first?.listID == b)
        #expect(!today.allDone)
    }

    @Test func finishingEverythingIsAllDone() async {
        let a = google.seedList("A")
        google.seedTask("Now", in: a, due: day(0))
        let store = await makeStore()
        #expect(store.today.progress == 0)
        store.setCompleted(store.today.dueToday[0].task, true, in: a)
        #expect(store.today.allDone)
        #expect(store.today.progress == 1)
        #expect(store.today.done.map(\.task.title) == ["Now"])
    }

    @Test func nothingDueIsNotACelebration() async {
        let a = google.seedList("A")
        google.seedTask("Someday", in: a)
        let store = await makeStore()
        #expect(store.today.remaining == 0)
        #expect(!store.today.allDone)
    }

    @Test func tasksDoneOnEarlierDaysDontCountAsDoneToday() async {
        let a = google.seedList("A")
        let id = google.seedTask("Old", in: a, due: day(-2), completed: true)
        _ = try? await google.patchTask(in: a, id: id, fields: ["completed": "2020-01-01T10:00:00.000Z"])
        let store = await makeStore()
        #expect(store.today.done.isEmpty)
        #expect(!store.today.allDone)
    }

    @Test func dueDatesAreCalendarDatesInEveryTimeZone() {
        // Google stores dates as midnight UTC; the local calendar date must be the same day everywhere.
        let task = TaskItem(id: "t", due: "2026-09-29T00:00:00.000Z")
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: task.dueDate!)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 29)
        #expect(TaskItem.dueString(for: task.dueDate!) == "2026-09-29T00:00:00.000Z")
    }
}
