// swift-tools-version: 6.4
// 6.4 is what `swift package init` writes for the installed toolchain (Apple Swift 6.4.2).
import PackageDescription

let package = Package(
    name: "Burnbar",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: parsing, pace, forecasting, formatting. No AppKit, so it is unit-testable.
        .target(name: "BurnbarCore"),
        .testTarget(
            name: "BurnbarCoreTests",
            dependencies: ["BurnbarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
