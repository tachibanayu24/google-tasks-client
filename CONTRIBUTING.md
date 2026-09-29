# Contributing

Thanks for your interest! Issues and pull requests are welcome.

## Setup

- macOS 26 and Xcode 26 (Swift 6.2).
- `swift build` compiles, and `swift test` runs the tests against an in-memory stand-in for Google Tasks.
- `./scripts/build-app.sh --dev` builds a separate **Google Tasks Client Dev.app** with its own bundle id, settings and Google account, so testing never touches your real setup.
- To work on the UI without a Google account, load sample data into the dev app:
  ```sh
  ./scripts/build-app.sh --dev && open -g "build/Google Tasks Client Dev.app"
  swift -e 'import Foundation; for n in ["demo", "preview"] { DistributedNotificationCenter.default().postNotificationName(.init("GoogleTasksClientDev." + n), object: nil, userInfo: nil, deliverImmediately: true); Thread.sleep(forTimeInterval: 0.5) }'
  ```
  The README lists the other notifications the dev app understands.

## Before opening a pull request

1. `swift build` finishes with no warnings from `Sources/`, and `swift test` passes. Changes to syncing come with a test in `Tests/`.
2. Try the change by hand in the dev app. Use the sample data, and a real Google account for anything that talks to the API.
3. If the UI changed, regenerate the README images with `./scripts/docs/capture.sh`. It takes over the middle of the screen for about half a minute.
4. Stay within what the Google Tasks API can do. The app doesn't imitate features the API lacks, such as times, repeats or stars.
5. Keep the style of the surrounding code: small focused types, comments that explain *why*, and English UI text.

## Changes to `Vendor/`

The vendored KeyboardShortcuts carries a small patch (marked `Google Tasks Client patch`). Keep it minimal and describe it in the package's `Package.swift` header.
