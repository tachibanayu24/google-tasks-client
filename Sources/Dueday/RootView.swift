import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var auth: GoogleAuth
    @ObservedObject var store: TaskStore
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Group {
            if auth.isSignedIn || store.isDemo {
                MainView(store: store)
            } else {
                SetupView(auth: auth)
            }
        }
        .font(.system(size: prefs.textSize))
        // The panel keeps its "active" look without focus; controls should too.
        .environment(\.controlActiveState, .key)
    }
}

private struct MainView: View {
    @ObservedObject var store: TaskStore
    /// One banner at a time at the bottom of the panel: naming a list, or confirming a deletion.
    @State private var banner: Banner?

    private enum Banner: Equatable {
        case create
        case rename(TaskList)
        case delete(TaskList)
    }

    var body: some View {
        VStack(spacing: 0) {
            ListTabBar(store: store,
                       onCreateList: { show(.create) },
                       onRenameList: { show(.rename($0)) },
                       onDeleteList: { show(.delete($0)) })
                .frame(height: 44)
            if let listID = store.selectedListID {
                AddTaskField(store: store)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                if store.showingToday {
                    TodayView(store: store)
                } else {
                    TaskListView(store: store, listID: listID)
                }
            } else {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
        }
        .overlay(alignment: .bottom) {
            if let banner {
                bannerView(banner)
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: store.isPanelOpen) { _, open in if !open { banner = nil } }
    }

    @ViewBuilder
    private func bannerView(_ banner: Banner) -> some View {
        switch banner {
        case .create:
            NameBanner(title: "New List", initial: "", action: "Create", onCommit: { name in
                store.createList(title: name)
                show(nil)
            }, onCancel: { show(nil) })
        case .rename(let list):
            NameBanner(title: "Rename List", initial: list.title, action: "Rename", onCommit: { name in
                store.renameList(list, to: name)
                show(nil)
            }, onCancel: { show(nil) })
        case .delete(let list):
            ConfirmBanner(message: "Delete “\(list.title)” and all its tasks?", action: "Delete",
                          onConfirm: {
                              store.deleteList(list)
                              show(nil)
                          },
                          onCancel: { show(nil) })
        }
    }

    private func show(_ banner: Banner?) {
        withAnimation(.snappy) { self.banner = banner }
    }
}

struct AddTaskField: View {
    @ObservedObject var store: TaskStore
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(focused ? Color.accentColor : .secondary)
                .frame(width: 18)
            // From Today, new tasks go to the first list, due today.
            TextField(store.showingToday ? "Add a task for today" : "Add a task", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    withAnimation(.snappy(duration: 0.25)) {
                        if store.showingToday {
                            store.addTask(title: draft, in: store.lists.first?.id, dueToday: true)
                        } else {
                            store.addTask(title: draft)
                        }
                    }
                    draft = ""
                }
                .onExitCommand { focused = false }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .glassEffect(.regular.tint(Color.primary.opacity(focused ? 0.06 : 0.03)), in: .capsule)
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .onReceive(store.focusAddField) { focused = true }
    }
}

struct ConfirmBanner: View {
    let message: String
    let action: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).font(.system(size: 13, weight: .medium))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(action, role: .destructive, action: onConfirm).keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// Names a list inside the panel (a popover wouldn't get the keyboard: the app is never activated).
struct NameBanner: View {
    let title: String
    let initial: String
    let action: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand(perform: onCancel)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(action, action: commit)
                    .buttonStyle(.glassProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onAppear {
            name = initial
            focused = true
        }
    }

    private func commit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onCommit(name)
    }
}

// MARK: - Setup

/// First run: the user brings their own OAuth client (this app ships none), then signs in.
struct SetupView: View {
    @ObservedObject var auth: GoogleAuth
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.tint)
                    Text("Connect Google Tasks")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Dueday talks to Google directly with your own OAuth client. Your tasks never pass through anyone else’s server.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Enable the Google Tasks API in a Google Cloud project.",
                         link: ("Open API Library", "https://console.cloud.google.com/apis/library/tasks.googleapis.com"))
                    step(2, "Set up the consent screen (External), then press “Publish app” under Audience — in Testing mode Google signs you out every 7 days.",
                         link: ("Open Audience", "https://console.cloud.google.com/auth/audience"))
                    step(3, "Create an OAuth client of type “Desktop app” and copy its ID and secret.",
                         link: ("Open Clients", "https://console.cloud.google.com/auth/clients"))
                    step(4, "Paste them below and sign in. Google will warn that the app isn’t verified — it’s your own app, so choose Advanced → Continue.",
                         link: nil)
                }

                VStack(spacing: 8) {
                    TextField("Client ID", text: $clientID)
                    SecureField("Client secret", text: $clientSecret)
                }
                .textFieldStyle(.roundedBorder)
                .disabled(auth.isSigningIn)

                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    if auth.isSigningIn {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the browser…").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { auth.cancelSignIn() }
                    } else {
                        Spacer()
                        Button("Sign in with Google", action: signIn)
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty
                                || clientSecret.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.never)
        .onAppear {
            clientID = auth.client?.clientID ?? ""
            clientSecret = auth.client?.clientSecret ?? ""
        }
    }

    private func step(_ n: Int, _ text: String, link: (String, String)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                if let (title, url) = link {
                    Link(title, destination: URL(string: url)!)
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    private func signIn() {
        error = nil
        Task {
            do {
                try await auth.signIn(with: OAuthClient(clientID: clientID, clientSecret: clientSecret))
            } catch AuthError.cancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
