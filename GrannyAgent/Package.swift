// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrannyAgent",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "GrannyCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "granny-agent",
            dependencies: ["GrannyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "granny-helper",
            dependencies: ["GrannyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GrannyCoreTests",
            dependencies: ["GrannyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
