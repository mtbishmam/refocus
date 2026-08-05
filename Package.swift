// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ReFocus",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RefocusCore", targets: ["RefocusCore"]),
        .executable(name: "ReFocus", targets: ["RefocusApp"]),
        .executable(name: "RefocusCoreChecks", targets: ["RefocusCoreChecks"]),
    ],
    targets: [
        .target(name: "RefocusCore"),
        .executableTarget(
            name: "RefocusApp",
            dependencies: ["RefocusCore"]
        ),
        .executableTarget(
            name: "RefocusCoreChecks",
            dependencies: ["RefocusCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
