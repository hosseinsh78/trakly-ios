# Trakly for iPhone

This repository is a read-only mirror of the iOS client of Trakly, an order and accounting system for shops. It holds
only what the iPhone app needs to build and be tested:

- `ios/`: the app (UIKit and SwiftUI, iOS 17 or later, iPhone only), its share extension, `TraklyCore` (the pure Swift
  logic, tested on Linux), the unit and UI tests and the XcodeGen project file;
- `shared/`: the bridge contract, the shared test fixtures, the native copy and the colour tokens the app is built from.

The Trakly server, the web panel and the Android app are developed in a private repository. Nothing here talks to a
production system during the tests: the UI tests run against a small local stand-in for the panel
(`ios/TraklyUITests/Panel/server.mjs`). Signing and App Store uploads do not happen in this repository.

Every commit here is generated from the private repository; changes are not accepted here.

## Build

GitHub Actions builds the app on macOS (`.github/workflows/ios.yml`): XcodeGen generates the Xcode project from
`ios/project.yml`, then `xcodebuild` builds and runs the tests on the iOS Simulator. `swift test` in `ios/TraklyCore`
runs on Linux.

## Licence

Copyright (c) 2026 Trakly. All rights reserved. The source is published for transparency and continuous integration
only; no licence is granted to use, copy, modify or distribute it.

The Vazirmatn font files in `ios/Trakly/Resources/Fonts/` are third-party work under the SIL Open Font License 1.1
(`OFL.txt` beside them); the rights statement above does not cover them.
