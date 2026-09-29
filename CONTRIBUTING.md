# Contributing

Thanks for your interest! Issues and pull requests are welcome.

## Setup

- macOS 26 and Xcode 26 (Swift 6.2).
- `swift build` compiles; `./scripts/build-app.sh --dev` builds a separate **Dueday Dev.app** (own bundle id, settings and Google account), so testing never touches your real setup.
- To work on the UI without a Google account, load sample data into the dev app:
  ```sh
  ./scripts/build-app.sh --dev && open -g "build/Dueday Dev.app"
  swift -e 'import Foundation; for n in ["demo", "preview"] { DistributedNotificationCenter.default().postNotificationName(.init("DuedayDev." + n), object: nil, userInfo: nil, deliverImmediately: true); Thread.sleep(forTimeInterval: 0.5) }'
  ```

## Before opening a pull request

1. `swift build` finishes with no warnings from `Sources/`, and `swift test` passes.
2. Try the change by hand in the dev app — with the sample data, and against a real Google account for anything that talks to the API.
3. Stay within what the Google Tasks API can do; Dueday doesn't imitate features the API lacks (times, repeats, stars).
4. Keep the style of the surrounding code: small focused types, comments that explain *why*, English UI text.

## Changes to `Vendor/`

The vendored KeyboardShortcuts carries a small patch (marked `Dueday patch`). Keep it minimal and describe it in the package's `Package.swift` header.
