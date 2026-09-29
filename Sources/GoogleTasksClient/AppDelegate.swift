import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
    private let auth = GoogleAuth.shared
    private var store: TaskStore!
    private var panel: PanelController!
    private var settingsWindow: NSWindow?
    private var backgroundSync: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let prefs = Preferences.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store = TaskStore(auth: auth, api: TasksAPI(auth: auth))
        panel = PanelController(store: store, auth: auth, menu: buildStatusMenu())

        buildMainMenu()
        // Signing in happens in the browser (which closes the panel); come back with the tasks once done.
        auth.$isSignedIn
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.panel.show() }
            .store(in: &cancellables)
        prefs.$theme
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in self?.settingsWindow?.appearance = theme.appearance }
            .store(in: &cancellables)
        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in self?.panel.toggle() }
        installDevHooks()
        startBackgroundSync()

        // First run: open the panel so the setup steps are right there (once the status item is laid out).
        if !auth.isSignedIn && !AppInfo.isDevBuild {
            DispatchQueue.main.async { self.panel.show() }
        }
    }

    /// The menu bar count must stay right while the panel is closed: re-sync every few minutes, after
    /// waking from sleep, and when the date changes (yesterday's "today" becomes overdue).
    private func startBackgroundSync() {
        Task { await store.refresh() }
        backgroundSync = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panel.isShown else { return }
                Task { await self.store.refresh() }
            }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .NSCalendarDayChanged))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.panel.updateStatusItem()
                // The network is often not back the instant the lid opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { await self.store.refresh() } }
            }
            .store(in: &cancellables)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.showOrFocus()
        return false
    }

    // MARK: Dev hooks

    /// Dev builds only: lets tests drive the panel without synthesizing keyboard/mouse input.
    private func installDevHooks() {
        guard AppInfo.isDevBuild else { return }
        observeDev("toggle") { app in
            app.panel.panel.allowsKey = true
            app.panel.toggle()
        }
        observeDev("demo") { app in app.store.loadDemo() }
        observeDev("next") { app in app.store.selectList(offset: 1) }
        observeDev("settings") { app in app.openSettings() }
        observeDev("finish") { app in
            let today = app.store.today
            withAnimation(.snappy) {
                for entry in today.overdue + today.dueToday { app.store.setCompleted(entry.task, true, in: entry.listID) }
            }
        }
        observeDev("preview") { app in
            app.panel.panel.allowsKey = false
            if app.panel.isShown { app.panel.hide() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.panel.show(takeFocus: false) }
        }
    }

    private func observeDev(_ name: String, _ handler: @escaping @MainActor (AppDelegate) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: .init("GoogleTasksClientDev." + name), object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
    }

    // MARK: Menus

    /// Right-click menu of the menu bar item.
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "")
        menu.addItem(withTitle: "Open Google Tasks", action: #selector(openGoogleTasks), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Google Tasks Client", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        return menu
    }

    /// Accessory apps show no menu bar, but key equivalents still route through the main menu.
    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Hide", action: #selector(hidePanel), keyEquivalent: "h").target = self
        appMenu.addItem(withTitle: "Quit Google Tasks Client", action: #selector(quitWithConfirmation), keyEquivalent: "q").target = self
        main.addItem(submenu: appMenu, title: "Google Tasks Client")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Task", action: #selector(newTask), keyEquivalent: "n").target = self
        file.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        file.addItem(withTitle: "Close", action: #selector(closeWindow), keyEquivalent: "w").target = self
        main.addItem(submenu: file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Bigger", action: #selector(increaseText), keyEquivalent: "+").target = self
        view.addItem(withTitle: "Bigger", action: #selector(increaseText), keyEquivalent: "=").target = self
        view.addItem(withTitle: "Smaller", action: #selector(decreaseText), keyEquivalent: "-").target = self
        view.addItem(withTitle: "Actual Size", action: #selector(resetText), keyEquivalent: "0").target = self
        view.addItem(.separator())
        let today = view.addItem(withTitle: "Today", action: #selector(showToday), keyEquivalent: "0")
        today.keyEquivalentModifierMask = [.command, .option]
        today.target = self
        let next = view.addItem(withTitle: "Next List", action: #selector(nextList), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        next.target = self
        let prev = view.addItem(withTitle: "Previous List", action: #selector(previousList), keyEquivalent: "[")
        prev.keyEquivalentModifierMask = [.command, .shift]
        prev.target = self
        let nextCtrl = view.addItem(withTitle: "Next List", action: #selector(nextList), keyEquivalent: "\t")
        nextCtrl.keyEquivalentModifierMask = [.control]
        nextCtrl.target = self
        let prevCtrl = view.addItem(withTitle: "Previous List", action: #selector(previousList), keyEquivalent: "\t")
        prevCtrl.keyEquivalentModifierMask = [.control, .shift]
        prevCtrl.target = self
        for i in 1...9 {
            let item = view.addItem(withTitle: "List \(i)", action: #selector(selectListByNumber(_:)), keyEquivalent: "\(i)")
            item.tag = i
            item.target = self
        }
        main.addItem(submenu: view, title: "View")

        NSApp.mainMenu = main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectListByNumber(_:)) { return menuItem.tag == 9 || menuItem.tag <= store.lists.count }
        if menuItem.action == #selector(newTask) || menuItem.action == #selector(refresh) { return auth.isSignedIn }
        return true
    }

    // MARK: Actions

    private var quitArmedUntil: Date?

    /// ⌘Q quits only when pressed twice in a row, so a stray keystroke never closes the panel.
    @objc private func quitWithConfirmation() {
        if let until = quitArmedUntil, Date() < until {
            NSApp.terminate(nil)
            return
        }
        guard panel.isShown else {
            NSApp.terminate(nil)
            return
        }
        quitArmedUntil = Date().addingTimeInterval(1.8)
        panel.showToast("Press ⌘Q again to quit")
    }

    @objc private func openGoogleTasks() { NSWorkspace.shared.open(URL(string: "https://tasks.google.com/")!) }
    @objc private func hidePanel() { panel.hide() }
    @objc private func newTask() {
        if !panel.isShown { panel.show() }
        store.focusAddField.send()
    }
    @objc private func refresh() { Task { await store.refresh() } }
    @objc private func closeWindow() {
        if let window = NSApp.keyWindow, window === settingsWindow {
            window.performClose(nil)
        } else {
            panel.hide()
        }
    }
    @objc private func showToday() { store.selectToday() }
    @objc private func nextList() { store.selectList(offset: 1) }
    @objc private func previousList() { store.selectList(offset: -1) }
    @objc private func selectListByNumber(_ sender: NSMenuItem) {
        // ⌘9 always means "last", like browsers.
        store.selectList(at: sender.tag == 9 ? store.lists.count - 1 : sender.tag - 1)
    }
    @objc private func increaseText() { prefs.textSize = min(Preferences.textSizeRange.upperBound, prefs.textSize + 1) }
    @objc private func decreaseText() { prefs.textSize = max(Preferences.textSizeRange.lowerBound, prefs.textSize - 1) }
    @objc private func resetText() { prefs.textSize = Preferences.defaultTextSize }

    /// Settings is an ordinary window: the panel steps aside and the app activates for it, so it can't end
    /// up behind the panel or floating over other apps.
    @objc func openSettings() {
        panel.hide()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            let host = NSHostingController(rootView: SettingsView(auth: auth))
            host.sizingOptions = [.preferredContentSize]
            window.contentViewController = host
            window.setContentSize(host.view.fittingSize)
            window.title = "Google Tasks Client Settings"
            window.appearance = prefs.theme.appearance
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
            window.center()
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Hand the keyboard back to the app used before Settings.
        guard (notification.object as? NSWindow) === settingsWindow, !panel.isShown else { return }
        NSApp.hide(nil)
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
