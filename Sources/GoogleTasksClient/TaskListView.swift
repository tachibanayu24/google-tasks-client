import AppKit
import SwiftUI

struct TaskListView: View {
    @ObservedObject var store: TaskStore
    let listID: String
    @AppStorage("showCompleted") private var showCompleted = false

    var body: some View {
        let rows = store.openRows(in: listID)
        let completed = store.completedTasks(in: listID)
        List {
            ForEach(rows) { row in
                TaskRow(store: store, task: row.task, depth: row.depth, listID: listID)
                    .modifier(RowChrome())
            }
            .onMove { store.move(from: $0, to: $1) }

            if rows.isEmpty && store.tasks[listID] != nil {
                EmptyState(hasCompleted: !completed.isEmpty)
                    .modifier(RowChrome())
            }

            if !completed.isEmpty {
                CompletedHeader(count: completed.count, expanded: $showCompleted)
                    .modifier(RowChrome())
                    .padding(.top, 6)
                if showCompleted {
                    ForEach(completed.map { TaskStore.Row(task: $0, depth: 0, id: store.rowID($0)) }) { row in
                        TaskRow(store: store, task: row.task, depth: 0, listID: listID)
                            .modifier(RowChrome())
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .animation(.snappy(duration: 0.28), value: rows.map(\.id))
        .animation(.snappy(duration: 0.28), value: completed.map(store.rowID))
        // Tasks scrolling up melt into the glass instead of being cut off at the add field.
        .mask(
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                   .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

private struct RowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

private struct EmptyState: View {
    let hasCompleted: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: hasCompleted ? "checkmark.circle" : "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(hasCompleted ? "All done" : "No tasks yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

private struct CompletedHeader: View {
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.28)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("Completed (\(count))")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

struct TaskRow: View {
    @ObservedObject var store: TaskStore
    let task: TaskItem
    let depth: Int
    let listID: String
    /// In the Today tab: rows come from several lists, so structure edits (subtasks, nesting) are off.
    var inToday = false
    @ObservedObject private var prefs = Preferences.shared

    @State private var title = ""
    @State private var notes = ""
    @State private var expanded = false
    @State private var hovering = false
    @State private var pickingDate = false
    /// Pending while the checkmark animates, before the task leaves for the Completed section.
    @State private var pendingCompletion: DispatchWorkItem?
    @FocusState private var titleFocused: Bool
    @FocusState private var notesFocused: Bool

    private var done: Bool { task.isCompleted || pendingCompletion != nil }
    /// Only real top-level tasks: not subtasks, nor subtasks shown at the top because their parent is done.
    private var canHaveSubtasks: Bool { task.parent == nil && !task.isCompleted && !inToday }
    /// In Today the date is implied by the section, unless it's overdue.
    private var showsDueChip: Bool {
        guard let due = task.dueDate else { return false }
        return !(inToday && Calendar.current.isDateInToday(due))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                CheckCircle(done: done, action: toggleDone)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Title", text: $title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .foregroundStyle(done ? .secondary : .primary)
                        .strikethrough(done, color: .secondary)
                        .onSubmit { titleFocused = false }
                        .onExitCommand { titleFocused = false }
                        .disabled(task.isCompleted)
                    details
                }
                Spacer(minLength: 0)
                // Kept while its date popover is up, so the popover keeps its anchor.
                if (hovering || pickingDate) && !expanded && !task.isCompleted {
                    hoverActions.transition(.opacity)
                }
            }
            if store.addingSubtaskTo == store.rowID(task) {
                SubtaskField(store: store, parent: task, listID: listID)
                    .padding(.leading, 28)
            }
        }
        .padding(.leading, CGFloat(depth) * 26 + 10)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(expanded ? 0.06 : hovering ? 0.035 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu { contextMenu }
        .onAppear {
            title = task.title ?? ""
            notes = task.notes ?? ""
        }
        .onChange(of: task.title) { _, new in if !titleFocused { title = new ?? "" } }
        .onChange(of: task.notes) { _, new in if !notesFocused { notes = new ?? "" } }
        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
        // Popovers go away with the panel; don't let their flags claim otherwise next time.
        .onChange(of: store.isPanelOpen) { _, open in if !open { pickingDate = false } }
        .onChange(of: notesFocused) { _, focused in if !focused { store.setNotes(task, notes, in: listID) } }
    }

    // MARK: Parts

    @ViewBuilder private var details: some View {
        if expanded {
            TextField("Details", text: $notes, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: prefs.textSize - 1))
                .foregroundStyle(.secondary)
                .lineLimit(1...12)
                .focused($notesFocused)
                .onExitCommand { notesFocused = false }
                .disabled(task.isCompleted)
        } else if let notes = task.notes, !notes.isEmpty {
            Text(notes)
                .font(.system(size: prefs.textSize - 1))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }

        let links = (task.links ?? []).filter { $0.link != nil }
        if showsDueChip || !links.isEmpty || expanded {
            HStack(spacing: 6) {
                if showsDueChip, let due = task.dueDate {
                    DueChip(date: due, done: task.isCompleted) { if !task.isCompleted { pickingDate = true } }
                        .popover(isPresented: $pickingDate, arrowEdge: .bottom) { datePicker }
                } else if expanded && !task.isCompleted {
                    ChipButton(icon: "calendar", label: task.dueDate == nil ? "Add date" : "Today") { pickingDate = true }
                        .popover(isPresented: $pickingDate, arrowEdge: .bottom) { datePicker }
                }
                ForEach(links, id: \.self) { link in
                    ChipButton(icon: Self.icon(for: link.type), label: link.description?.isEmpty == false ? link.description! : "Link") {
                        if let url = link.link.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
                    }
                }
                if expanded {
                    Spacer(minLength: 0)
                    if canHaveSubtasks {
                        IconButton(icon: "arrow.turn.down.right", help: "Add Subtask") { store.addingSubtaskTo = store.rowID(task) }
                    }
                    if let link = task.webViewLink.flatMap(URL.init(string:)) {
                        IconButton(icon: "arrow.up.forward.square", help: "Open in Google Tasks") { NSWorkspace.shared.open(link) }
                    }
                    IconButton(icon: "trash", help: "Delete") { withAnimation(.snappy) { store.delete(task, in: listID) } }
                }
            }
            .padding(.top, 2)
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 0) {
            if !showsDueChip {
                IconButton(icon: "calendar", help: task.dueDate == nil ? "Add date" : "Change date") { pickingDate = true }
                    .popover(isPresented: Binding(get: { pickingDate && !showsDueChip && !expanded },
                                                  set: { pickingDate = $0 }), arrowEdge: .bottom) { datePicker }
            }
            IconButton(icon: "chevron.down", help: "Details") {
                withAnimation(.snappy(duration: 0.25)) { expanded = true }
            }
        }
    }

    private var datePicker: some View {
        DuePicker(initial: task.dueDate) { date in
            store.setDue(task, date, in: listID)
            pickingDate = false
        }
    }

    @ViewBuilder private var contextMenu: some View {
        if !task.isCompleted && inToday {
            Button("Postpone to Tomorrow") {
                withAnimation(.snappy) { store.setDue(task, Calendar.current.date(byAdding: .day, value: 1, to: Date()), in: listID) }
            }
            Divider()
        }
        if !task.isCompleted && !inToday {
            if canHaveSubtasks {
                Button("Add Subtask") { store.addingSubtaskTo = store.rowID(task) }
            }
            if store.canIndent(task) {
                Button("Make Subtask") { withAnimation(.snappy) { store.indent(task) } }
            }
            if task.parent != nil {
                Button("Move Out of Subtask") { withAnimation(.snappy) { store.outdent(task) } }
            }
            let others = store.lists.filter { $0.id != listID }
            if !others.isEmpty {
                Menu("Move to") {
                    ForEach(others) { list in
                        Button(list.title) { withAnimation(.snappy) { store.moveToList(task, from: listID, to: list.id) } }
                    }
                }
            }
            Divider()
        }
        if let link = task.webViewLink.flatMap(URL.init(string:)) {
            Button("Open in Google Tasks") { NSWorkspace.shared.open(link) }
        }
        Button("Copy Title") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.title ?? "", forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) { withAnimation(.snappy) { store.delete(task, in: listID) } }
    }

    // MARK: Actions

    private func toggleDone() {
        // A second click while the check is landing takes it back.
        if let pending = pendingCompletion {
            pending.cancel()
            withAnimation(.snappy(duration: 0.2)) { pendingCompletion = nil }
            return
        }
        if task.isCompleted {
            withAnimation(.snappy) { store.setCompleted(task, false, in: listID) }
            return
        }
        commitTitle()
        let work = DispatchWorkItem { [task, listID, store] in
            withAnimation(.snappy(duration: 0.3)) { store.setCompleted(task, true, in: listID) }
        }
        withAnimation(.snappy(duration: 0.2)) { pendingCompletion = work }
        // Let the check land before the task slides away into Completed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard !work.isCancelled else { return }
            work.perform()
            pendingCompletion = nil
        }
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            title = task.title ?? ""
        } else {
            store.rename(task, to: trimmed, in: listID)
        }
    }

    private static func icon(for type: String?) -> String {
        switch type {
        case "email": "envelope"
        case "chat_message": "bubble.left"
        case "keep_note": "note.text"
        default: "link"
        }
    }
}

private struct SubtaskField: View {
    @ObservedObject var store: TaskStore
    let parent: TaskItem
    let listID: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            TextField("Subtask", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    withAnimation(.snappy) { store.addTask(title: draft, parent: parent, in: listID) }
                    draft = ""
                }
                .onExitCommand { store.addingSubtaskTo = nil }
        }
        .padding(.vertical, 4)
        .onAppear { focused = true }
        .onChange(of: focused) { _, f in
            if !f && draft.isEmpty && store.addingSubtaskTo == store.rowID(parent) { store.addingSubtaskTo = nil }
        }
    }
}

private struct CheckCircle: View {
    let done: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(done ? Color.accentColor : Color.primary.opacity(0.35), lineWidth: 1.5)
                    .background(Circle().fill(done ? Color.accentColor : .clear))
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(done ? Color.white : Color.primary.opacity(0.45))
                    .opacity(done || hovering ? 1 : 0)
                    .scaleEffect(done ? 1 : 0.8)
            }
            .frame(width: 17, height: 17)
            .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.bouncy(duration: 0.3, extraBounce: 0.1), value: done)
    }
}

private struct DueChip: View {
    let date: Date
    let done: Bool
    let action: () -> Void

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let overdue = !done && date < today
        let isToday = Calendar.current.isDate(date, inSameDayAs: today)
        ChipButton(icon: "calendar", label: Self.label(date),
                   tint: done ? nil : overdue ? .red : isToday ? .accentColor : nil,
                   action: action)
    }

    static func label(_ date: Date) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case -6 ... -2: return "\(-days) days ago"
        case 2...6: return date.formatted(.dateTime.weekday(.wide))
        default:
            let sameYear = cal.component(.year, from: date) == cal.component(.year, from: today)
            return sameYear ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                            : date.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}

private struct ChipButton: View {
    let icon: String
    let label: String
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill((tint ?? .primary).opacity(hovering ? 0.16 : 0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(HoverCircleStyle())
        .help(help)
    }
}

private struct DuePicker: View {
    let initial: Date?
    let onPick: (Date?) -> Void
    @State private var date = Date()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                quick("Today", Date())
                quick("Tomorrow", Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
                quick("Next Week", Calendar.current.date(byAdding: .day, value: 7, to: Date())!)
            }
            DatePicker("", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                if initial != nil {
                    Button("Remove Date", role: .destructive) { onPick(nil) }
                }
                Spacer()
                Button("Done") { onPick(date) }.keyboardShortcut(.defaultAction)
            }
            // Google Tasks stores dates only; the API can't set a time.
        }
        .padding(12)
        .frame(width: 240)
        .onAppear { date = initial ?? Date() }
    }

    private func quick(_ label: String, _ date: Date) -> some View {
        Button(label) { onPick(date) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}
