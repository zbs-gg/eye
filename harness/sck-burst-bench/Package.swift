// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SckBurstBench",
    platforms: [.macOS(.v14)],          // SCScreenshotManager.captureImage требует macOS 14+
    targets: [
        .executableTarget(
            name: "SckBurstBench",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
