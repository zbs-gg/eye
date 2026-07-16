// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZBSEyeWhisper",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ZBSEyeWhisper", targets: ["ZBSEyeWhisper"]),
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-v1.9.1-xcframework.zip",
            checksum: "8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
        ),
        .target(
            name: "ZBSEyeWhisper",
            dependencies: ["whisper"]
        ),
    ]
)
