// swift-tools-version:6.2
// Vendored from https://github.com/sindresorhus/KeyboardShortcuts (MIT) — patched for Dueday:
// localized strings are compiled in (English only) so no SwiftPM resource bundle is needed.
import PackageDescription

let package = Package(
	name: "KeyboardShortcuts",
	platforms: [
		.macOS(.v10_15)
	],
	products: [
		.library(
			name: "KeyboardShortcuts",
			targets: [
				"KeyboardShortcuts"
			]
		)
	],
	targets: [
		.target(
			name: "KeyboardShortcuts",
			swiftSettings: [
				.defaultIsolation(MainActor.self),
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances")
			]
		)
	]
)
