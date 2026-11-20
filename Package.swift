// swift-tools-version: 6.4
// 6.4 is what `swift package init` writes for the installed toolchain (Apple Swift 6.4.2).
import PackageDescription

let package = Package(
    name: "Burnbar",
    // 14: NSMenuItem.sectionHeader is used in the dropdown.
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: parsing, pace, forecasting, formatting. No AppKit, so it is unit-testable.
        .target(name: "BurnbarCore"),
        // The menu bar app itself.
        .executableTarget(name: "Burnbar", dependencies: ["BurnbarCore"]),
        .testTarget(
            name: "BurnbarCoreTests",
            dependencies: ["BurnbarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
