// swift-tools-version:5.10
// The pure logic of the iOS app (docs/specs/phase10-apps-and-stores.md D19, §E1, §E2, §K5): Foundation only, no UIKit,
// no WebKit, no third-party package. `swift test` runs it on Linux (the mirror's ios.yml and the private repo's
// checks.yml) and on macOS; the app links it as a local package. Swift 5 language mode.
import PackageDescription

let package = Package(
    name: "TraklyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TraklyCore", targets: ["TraklyCore"]),
    ],
    targets: [
        // DEBUG only in a debug build: the local fixture origins of `Limits.devOrigins` never reach a release build.
        .target(name: "TraklyCore", path: "Sources/TraklyCore", swiftSettings: [.define("DEBUG", .when(configuration: .debug))]),
        .testTarget(name: "TraklyCoreTests", dependencies: ["TraklyCore"], path: "Tests/TraklyCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
