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
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.1.3/TranscribeCpp.xcframework.zip",
            checksum: "b7a3442e2f3552cac1ee71b5e164934dd4db243f6b4b16b1e3e3ed5d1645eefd"
        ),
        .target(
            name: "ZBSEyeWhisper",
            dependencies: ["whisper", "CTranscribe"]
        ),
    ]
)
