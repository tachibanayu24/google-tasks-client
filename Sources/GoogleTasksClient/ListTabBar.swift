import AppKit
import SwiftUI

/// Task lists as tabs. The selected one sits on a raised Liquid Glass capsule that morphs between tabs.
/// (Google Tasks can't reorder lists through its API, so tabs can't be dragged.)
struct ListTabBar: View {
    @ObservedObject var store: TaskStore
    var onCreateList: () -> Void
    var onRenameList: (TaskList) -> Void
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 2) {
                            ListChip(title: "Today", badge: store.today.remaining, isSelected: store.showingToday, namespace: selection)
                                .id("today")
                                .onTapGesture { withAnimation(.bouncy(duration: 0.35)) { store.selectToday() } }
                            ForEach(store.lists) { list in
                                ListChip(title: list.title, isSelected: !store.showingToday && list.id == store.selectedListID,
                                         namespace: selection)
                                    .id(list.id)
                                    .onTapGesture { withAnimation(.bouncy(duration: 0.35)) { store.select(listID: list.id) } }
                                    .contextMenu {
                                        Button("Rename…") { onRenameList(list) }
                                    }
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                        .animation(.bouncy(duration: 0.38, extraBounce: 0.04), value: store.selectedListID)
                        .animation(.bouncy(duration: 0.38, extraBounce: 0.04), value: store.showingToday)
                    }
                }
                .scrollClipDisabled()
                .onChange(of: store.selectedListID) { _, id in
                    withAnimation(.snappy) { proxy.scrollTo(id) }
                }
                .onChange(of: store.showingToday) { _, today in
                    if today { withAnimation(.snappy) { proxy.scrollTo("today") } }
                }
            }

            Button(action: onCreateList) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(HoverCircleStyle())
            .foregroundStyle(.secondary)
            .help("New List")

            ListMenu(store: store, onRename: onRenameList)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct ListMenu: View {
    @ObservedObject var store: TaskStore
    var onRename: (TaskList) -> Void

    var body: some View {
        Menu {
            if let problem = store.syncProblem {
                Text(problem)
                Divider()
            }
            Button("Refresh") { Task { await store.refresh() } }
            if let list = store.selectedList, !store.showingToday {
                Divider()
                Button("Rename List…") { onRename(list) }
            }
            Divider()
            Button("Open Google Tasks") { NSWorkspace.shared.open(URL(string: "https://tasks.google.com/")!) }
            Button("Settings…") { NSApp.sendAction(#selector(AppDelegate.openSettings), to: nil, from: nil) }
        } label: {
            Image(systemName: store.isSyncing ? "arrow.triangle.2.circlepath"
                : store.syncProblem != nil ? "exclamationmark.icloud" : "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .symbolEffect(.rotate, isActive: store.isSyncing)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(HoverCircleStyle())
        .menuIndicator(.hidden)
        .foregroundStyle(store.syncProblem != nil && !store.isSyncing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .help(store.syncProblem ?? "")
        .fixedSize()
    }
}

private struct ListChip: View {
    let title: String
    var badge = 0
    let isSelected: Bool
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 5) {
            Text(title.isEmpty ? "Untitled" : title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: 150)
                .fixedSize(horizontal: true, vertical: false)
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Color.accentColor))
                    .contentTransition(.numericText())
            }
        }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .modifier(SelectionBackground(isSelected: isSelected, namespace: namespace))
            .contentShape(Capsule())
    }
}

private struct SelectionBackground: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if isSelected {
            content
                .glassEffect(.regular.tint(Color.primary.opacity(0.1)), in: .capsule)
                .glassEffectID("selection", in: namespace)
                .modifier(RaisedShadow())
        } else {
            content
        }
    }
}

/// Neumorphic lift: light from the top-left, soft shade to the bottom-right.
struct RaisedShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .shadow(color: .white.opacity(scheme == .dark ? 0.06 : 0.7), radius: 3, x: -2, y: -2)
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 4, x: 2, y: 3)
    }
}

struct HoverCircleStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0)))
            .onHover { hovering = $0 }
    }
}
