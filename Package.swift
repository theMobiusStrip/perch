// swift-tools-version:6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Perch", targets: ["Perch"]),
        .executable(name: "perch-bridge", targets: ["PerchBridge"]),
        .executable(name: "PerchFuzz", targets: ["PerchFuzz"]),
        .executable(name: "PerchMeta", targets: ["PerchMeta"]),
    ],
    targets: [
        .target(
            name: "PerchCore",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "PerchBridge",
            dependencies: ["PerchCore"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "Perch",
            dependencies: ["PerchCore"],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Harness tooling — offline oracles for bug-bashing PerchCore. Not
        // shipped in the app bundle (Makefile copies only Perch/perch-bridge).
        .executableTarget(
            name: "PerchFuzz",
            dependencies: ["PerchCore"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "PerchMeta",
            dependencies: ["PerchCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
