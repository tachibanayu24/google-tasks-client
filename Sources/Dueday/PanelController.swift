import AppKit
import Combine
import SwiftUI

/// Borderless glass panel that drops from the menu bar. It takes keyboard focus without activating the app
/// (like Spotlight), so opening it never depends on macOS agreeing to activate us.
final class TasksPanel: NSPanel {
    /// Dev builds run next to the user's real work: they may only take the keyboard when a test explicitly asks.
    var allowsKey = !AppInfo.isDevBuild
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { true }
    var onCancel: (() -> Void)?

    /// Liquid Glass (and glass controls) switch to a lighter "inactive" rendering when the window loses key
    /// status. AppKit asks these (private) hooks which look to use; always answering "active" keeps the panel
    /// identical with or without focus. Key handling itself is untouched.
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func hasKeyAppearance() -> Bool { true }

    /// The app is usually not active, so ⌘-shortcuts must be routed to the main menu here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    /// Esc closes the panel (text fields that are being edited handle Esc themselves first).
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the menu bar item and the panel it opens.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: TasksPanel
    let store: TaskStore
    private let auth: GoogleAuth
    private let prefs = Preferences.shared

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu: NSMenu
    private let toast = ToastView()
    private let glass = NSGlassEffectView()
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?

    private(set) var isShown = false
    private var animationGeneration = 0
    private var pollTimer: Timer?

    private let cornerRadius: CGFloat = 22
    private let size = NSSize(width: 380, height: 580)
    /// While open, lists are re-read this often to pick up edits made elsewhere.
    private let pollInterval: TimeInterval = 30

    init(store: TaskStore, auth: GoogleAuth, menu: NSMenu) {
        self.store = store
        self.auth = auth
        self.menu = menu
        panel = TasksPanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        super.init()
        configurePanel()
        buildContent()
        configureStatusItem()
        bind()
    }

    // MARK: Setup

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
    }

    private func buildContent() {
        // Clipped to the rounded shape: the active glass rendering otherwise tints the square corners too.
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = cornerRadius
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        panel.contentView = root

        // Apple's clear glass at the bottom, regular glass above it faded in by the Opacity setting.
        let clearGlass = NSGlassEffectView()
        clearGlass.style = .clear
        clearGlass.cornerRadius = cornerRadius
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        let host = NSHostingView(rootView: RootView(auth: auth, store: store))
        for v in [clearGlass, glass, host] as [NSView] {
            v.frame = root.bounds
            v.autoresizingMask = [.width, .height]
            root.addSubview(v)
        }
        toast.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        updateStatusItem()
    }

    private func bind() {
        store.messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.toast.show(message) }
            .store(in: &cancellables)

        // The count follows every local edit and every sync.
        store.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        auth.$isSignedIn
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }
            .store(in: &cancellables)

        prefs.$opacity.combineLatest(prefs.$theme)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.applyAppearance() }
            .store(in: &cancellables)

        panel.publisher(for: \.effectiveAppearance)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyAppearance() }
            .store(in: &cancellables)
    }

    private func applyAppearance() {
        panel.appearance = prefs.theme.appearance
        let base = panel.effectiveAppearance.isDark
            ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.985, blue: 0.98, alpha: 1)
        // 0 = Apple's clear glass, 0.5 = regular glass, 1 = regular glass with a solid tint.
        let v = prefs.opacity
        glass.alphaValue = min(1, v / 0.5)
        glass.tintColor = v > 0.5 ? base.withAlphaComponent((v - 0.5) / 0.5 * 0.85) : nil
    }

    func showToast(_ message: String) {
        toast.show(message)
    }

    // MARK: Menu bar item

    private var lastAllDone = false

    /// Today's remaining count next to a progress ring; a party popper once everything due is done.
    func updateStatusItem() {
        guard let button = statusItem.button else { return }
        guard auth.isSignedIn || store.isDemo else {
            button.image = StatusIcon.symbol("checklist")
            button.title = ""
            button.toolTip = "Dueday — not signed in"
            return
        }
        let today = store.today
        if today.allDone {
            button.image = StatusIcon.celebration()
            button.title = ""
            button.toolTip = today.done.count == 1 ? "All done — 1 task completed today" : "All done — \(today.done.count) tasks completed today"
        } else if today.remaining == 0 {
            button.image = StatusIcon.symbol("checkmark.circle")
            button.title = ""
            button.toolTip = "Nothing due today"
        } else {
            button.image = StatusIcon.ring(progress: today.progress)
            button.attributedTitle = NSAttributedString(string: " \(today.remaining)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .baselineOffset: 0.5,
            ])
            var parts: [String] = []
            if !today.overdue.isEmpty { parts.append("\(today.overdue.count) overdue") }
            if !today.dueToday.isEmpty { parts.append("\(today.dueToday.count) due today") }
            if !today.done.isEmpty { parts.append("\(today.done.count) done") }
            button.toolTip = parts.joined(separator: " · ")
        }
        if today.allDone && !lastAllDone { bounceStatusItem() }
        lastAllDone = today.allDone
    }

    private func bounceStatusItem() {
        guard let layer = statusItem.button?.layer else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1, 1.35, 0.9, 1.1, 1]
        bounce.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        bounce.duration = 0.6
        layer.add(bounce, forKey: "bounce")
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            hide()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        toggle()
    }

    // MARK: Show / hide

    func toggle() {
        isShown ? hide() : show()
    }

    func showOrFocus() {
        isShown ? focus() : show()
    }

    /// `takeFocus: false` only for dev previews.
    func show(takeFocus: Bool = true) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let height = min(size.height, vf.height - 16)
        let x = min(max(vf.minX + 8, anchor.midX - size.width / 2), vf.maxX - size.width - 8)
        let target = NSRect(x: round(x), y: round(anchor.minY - 6 - height), width: size.width, height: height)

        animationGeneration += 1
        isShown = true
        statusItem.button?.highlight(true)
        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 0, dy: 10), display: false)
        panel.orderFrontRegardless()
        if takeFocus { focus() }
        startPolling()
        installOutsideClickMonitor()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShown else { return }
        // Commit whatever field is being edited before the panel goes away.
        panel.makeFirstResponder(nil)
        stopPolling()
        removeOutsideClickMonitor()
        animationGeneration += 1
        let generation = animationGeneration
        isShown = false
        statusItem.button?.highlight(false)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 6), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.animationGeneration else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func focus() {
        panel.makeKeyAndOrderFront(nil)
    }

    /// Like a menu: a click anywhere else closes the panel. (Clicks in our own popovers and Settings are
    /// events of this app, which a global monitor never sees.)
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    // MARK: Sync while open

    private func startPolling() {
        Task { await store.refresh() }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.store.refresh() }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

/// Menu bar images. Template images follow the menu bar's own light/dark rendering.
enum StatusIcon {
    static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Dueday")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        return image
    }

    /// A ring filling up as today's tasks get done.
    static func ring(progress: Double) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 2, dy: 2)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            if progress > 0 {
                let arc = NSBezierPath()
                let center = NSPoint(x: rect.midX, y: rect.midY)
                arc.appendArc(withCenter: center, radius: inset.width / 2, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(min(progress, 1)), clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The one colored icon: a party popper once the day is done.
    static func celebration() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(.init(paletteColors: [.systemOrange, .systemPink]))
        let image = NSImage(systemSymbolName: "party.popper.fill", accessibilityDescription: "All done")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }
}

/// A small glass pill message that fades in and out at the bottom of the panel.
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let glass = NSGlassEffectView()
        glass.cornerRadius = 14
        let inner = NSView()
        glass.contentView = inner
        inner.addSubview(label)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ message: String) {
        label.stringValue = message
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}
