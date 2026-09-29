import SwiftUI

/// Everything due today or earlier, across all lists — what the menu bar counts.
struct TodayView: View {
    @ObservedObject var store: TaskStore
    @State private var confetti = 0

    var body: some View {
        let today = store.today
        List {
            TodayHeader(today: today)
                .modifier(TodayRowChrome())
                .padding(.bottom, 4)

            if today.allDone {
                Celebration(count: today.done.count)
                    .modifier(TodayRowChrome())
            } else if today.remaining == 0 {
                Calm()
                    .modifier(TodayRowChrome())
            }

            section("Overdue", entries: today.overdue, tint: .red)
            section("Today", entries: today.dueToday, tint: nil)
            section("Done", entries: today.done, tint: nil)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .animation(.snappy(duration: 0.3), value: today)
        .overlay { ConfettiView(trigger: confetti).allowsHitTesting(false) }
        .onChange(of: today.allDone) { was, now in
            // Only for finishing the day here, not for opening an already finished day.
            if now && !was { confetti += 1 }
        }
    }

    @ViewBuilder
    private func section(_ title: String, entries: [TaskStore.Entry], tint: Color?) -> some View {
        if !entries.isEmpty {
            HStack(spacing: 6) {
                Text(title)
                Text("\(entries.count)").foregroundStyle(.tertiary)
                Spacer()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .modifier(TodayRowChrome())
            ForEach(entries) { entry in
                TaskRow(store: store, task: entry.task, depth: 0, listID: entry.listID, inToday: true)
                    .modifier(TodayRowChrome())
            }
        }
    }
}

private struct TodayRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

private struct TodayHeader: View {
    let today: TaskStore.Today

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date().formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 22, weight: .bold))
                Text(Date().formatted(.dateTime.month(.wide).day()))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if today.remaining + today.done.count > 0 {
                ProgressRing(progress: today.progress, done: today.done.count, total: today.remaining + today.done.count)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

private struct ProgressRing: View {
    let progress: Double
    let done: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 4)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(AngularGradient(colors: [.teal, .blue, .teal], center: .center),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(done)/\(total)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 42, height: 42)
        .animation(.snappy(duration: 0.5), value: progress)
    }
}

private struct Celebration: View {
    let count: Int
    @State private var bounce = 0

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 40))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .symbolEffect(.bounce, value: bounce)
            Text("All done for today")
                .font(.system(size: 15, weight: .semibold))
            Text(count == 1 ? "1 task completed" : "\(count) tasks completed")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .onAppear { bounce += 1 }
    }
}

private struct Calm: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sun.max")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.orange.opacity(0.8))
            Text("Nothing due today")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// A short burst of confetti from the top whenever `trigger` changes.
struct ConfettiView: View {
    let trigger: Int
    @State private var start: Date?
    @State private var pieces: [Piece] = []
    private let duration: TimeInterval = 2.4

    struct Piece {
        var x: Double, vx: Double, vy: Double, spin: Double, size: CGSize, color: Color, phase: Double
    }

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            Canvas { ctx, size in
                guard let start else { return }
                let t = context.date.timeIntervalSince(start)
                let fade = max(0, min(1, (duration - t) / 0.6))
                for p in pieces {
                    let x = p.x * size.width + p.vx * t
                    let y = -10 + p.vy * t + 260 * t * t
                    guard y < size.height + 20 else { continue }
                    var c = ctx
                    c.opacity = fade
                    c.translateBy(x: x + sin(t * 6 + p.phase) * 8, y: y)
                    c.rotate(by: .radians(p.spin * t + p.phase))
                    // Flip on one axis to fake a tumbling paper.
                    c.scaleBy(x: 1, y: cos(t * 7 + p.phase))
                    c.fill(Path(roundedRect: CGRect(origin: CGPoint(x: -p.size.width / 2, y: -p.size.height / 2), size: p.size),
                                cornerRadius: 1.5), with: .color(p.color))
                }
            }
        }
        .onChange(of: trigger) { _, _ in burst() }
    }

    private func burst() {
        let colors: [Color] = [.pink, .orange, .yellow, .mint, .teal, .blue, .purple]
        pieces = (0..<90).map { _ in
            Piece(x: .random(in: 0.1...0.9), vx: .random(in: -60...60), vy: .random(in: -40...120),
                  spin: .random(in: -8...8), size: CGSize(width: .random(in: 5...8), height: .random(in: 8...12)),
                  color: colors.randomElement()!, phase: .random(in: 0...(2 * .pi)))
        }
        start = Date()
        let token = trigger
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if token == trigger { start = nil }
        }
    }
}
