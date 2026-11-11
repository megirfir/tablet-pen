// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TabletPen",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic (protocol, mapping, gestures, curves): no AppKit, fully unit-testable.
        .target(name: "TabletPenCore"),
        .executableTarget(name: "TabletPenMac", dependencies: ["TabletPenCore"]),
        .testTarget(name: "TabletPenCoreTests", dependencies: ["TabletPenCore"]),
    ]
)
