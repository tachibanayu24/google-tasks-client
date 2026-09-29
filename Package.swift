// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Dueday",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "Vendor/KeyboardShortcuts"),  // patched: no resource bundle
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Dueday",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
            ],
            path: "Sources/Dueday",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DuedayTests",
            dependencies: ["Dueday"],
            path: "Tests/DuedayTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
