import AppKit

enum AppInfo {
    /// `scripts/build-app.sh --dev` builds a separate app (own bundle id, settings and account) for testing.
    static let isDevBuild = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
