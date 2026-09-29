import AppKit
import Combine
import KeyboardShortcuts

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension KeyboardShortcuts.Name {
    /// Optional: the menu bar item is the main way in.
    static let togglePanel = Self("togglePanel")
}

final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    /// 0 = Apple's clear Liquid Glass, 0.5 = regular Liquid Glass, 1 = tinted, nearly solid.
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: "opacity") } }
    @Published var theme: ThemeMode { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var textSize: Double { didSet { defaults.set(textSize, forKey: "textSize") } }

    static let textSizeRange: ClosedRange<Double> = 11...18
    static let defaultTextSize: Double = 13

    private init() {
        opacity = defaults.object(forKey: "opacity") as? Double ?? 0.5
        theme = ThemeMode(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        textSize = defaults.object(forKey: "textSize") as? Double ?? Preferences.defaultTextSize
    }
}
