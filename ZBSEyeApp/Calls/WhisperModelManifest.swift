import Foundation
import ZBSEyeWhisper

struct WhisperModelManifest: Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    let repositoryID: String
    let revision: String
    let sourceURL: URL
    let relativePath: String
    let expectedBytes: Int64
    let sha256: String
    let licenseSPDX: String
    let licenseURL: URL
    let runtimeRelease: String
    let runtimeArchiveSHA256: String

    static let largeV3Turbo = WhisperModelManifest(
        id: "whisper-large-v3-turbo-v1",
        displayName: "Whisper Large V3 Turbo",
        repositoryID: "ggerganov/whisper.cpp",
        revision: "98aa99a0a9db05ae2342309f5096248665f7cba3",
        sourceURL: URL(
            string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/98aa99a0a9db05ae2342309f5096248665f7cba3/ggml-large-v3-turbo.bin"
        )!,
        relativePath: "model/ggml-large-v3-turbo.bin",
        expectedBytes: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        licenseSPDX: "MIT",
        licenseURL: URL(string: "https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/LICENSE")!,
        runtimeRelease: WhisperRuntimeIdentity.release,
        runtimeArchiveSHA256: WhisperRuntimeIdentity.archiveSHA256
    )
}
