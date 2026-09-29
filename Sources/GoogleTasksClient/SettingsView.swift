import AppKit
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var auth: GoogleAuth
    @State private var confirmingForget = false

    var body: some View {
        Form {
            Section("Google Account") {
                if auth.isSignedIn {
                    LabeledContent("Status") {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    LabeledContent("OAuth Client") {
                        Text(shortID(auth.client?.clientID ?? ""))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Spacer()
                        Button("Sign Out") { auth.signOut() }
                    }
                } else {
                    Text("Not connected. Click the menu bar icon to sign in.")
                        .foregroundStyle(.secondary)
                    if auth.client != nil {
                        HStack {
                            Spacer()
                            Button("Forget OAuth Client…") { confirmingForget = true }
                        }
                    }
                }
            }

            Section {
                KeyboardShortcuts.Recorder("Open with shortcut", name: .togglePanel)
            }

            Section("Appearance") {
                Picker("Theme", selection: $prefs.theme) {
                    ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Opacity") {
                    HStack {
                        Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                        Slider(value: $prefs.opacity, in: 0...1)
                        Image(systemName: "circle.fill").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Text Size") {
                    HStack {
                        Slider(value: $prefs.textSize, in: Preferences.textSizeRange, step: 1)
                        Text("\(Int(prefs.textSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section {
                LaunchAtLogin.Toggle("Launch at login")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .confirmationDialog("Forget the saved OAuth client?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { auth.forgetClient() }
        } message: {
            Text("You’ll need to paste the Client ID and secret again to sign in.")
        }
    }

    private func shortID(_ id: String) -> String {
        guard id.count > 24 else { return id }
        return String(id.prefix(12)) + "…" + String(id.suffix(24))
    }
}
