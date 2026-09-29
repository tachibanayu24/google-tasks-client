// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "GoogleTasksClient",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "Vendor/KeyboardShortcuts"),  // patched: no resource bundle
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "GoogleTasksClient",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
            ],
            path: "Sources/GoogleTasksClient",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GoogleTasksClientTests",
            dependencies: ["GoogleTasksClient"],
            path: "Tests/GoogleTasksClientTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
