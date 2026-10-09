// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PicCompress",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CZlib",
            path: "Sources/CZlib",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "PicCompress",
            dependencies: ["CZlib"],
            path: "Sources/PicCompress",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
