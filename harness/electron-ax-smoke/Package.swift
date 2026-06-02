// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ElectronAXSmoke",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ElectronAXSmoke",
            path: "Sources/ElectronAXSmoke"
        )
    ]
)
