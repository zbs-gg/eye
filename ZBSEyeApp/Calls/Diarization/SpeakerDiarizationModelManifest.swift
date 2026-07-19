import Foundation

struct SpeakerDiarizationModelFile: Codable, Equatable, Sendable {
    let relativePath: String
    let expectedBytes: Int64
    let sha256: String
}

struct SpeakerDiarizationModelManifest: Codable, Equatable, Sendable {
    let packageVersion: String
    let packageCommit: String
    let repositoryID: String
    let modelRevision: String
    let packageLicense: String
    let modelLicense: String
    let files: [SpeakerDiarizationModelFile]

    var expectedBytes: Int64 { files.reduce(0) { $0 + $1.expectedBytes } }

    func sourceURL(for file: SpeakerDiarizationModelFile) -> URL {
        let encodedPath = file.relativePath
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string:
            "https://huggingface.co/\(repositoryID)/resolve/\(modelRevision)/\(encodedPath)?download=true"
        )!
    }

    static let fluidAudio0155 = SpeakerDiarizationModelManifest(
        packageVersion: "0.15.5",
        packageCommit: "19600a485baa4998812e4654b70d2bab8f2c9949",
        repositoryID: "FluidInference/speaker-diarization-coreml",
        modelRevision: "1ed7a662fdc7109e36d822db793ee6eebdaf8594",
        packageLicense: "Apache-2.0",
        modelLicense: "CC-BY-4.0",
        files: [
            .init(relativePath: "Embedding.mlmodelc/analytics/coremldata.bin", expectedBytes: 243, sha256: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
            .init(relativePath: "Embedding.mlmodelc/coremldata.bin", expectedBytes: 704, sha256: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
            .init(relativePath: "Embedding.mlmodelc/metadata.json", expectedBytes: 2_818, sha256: "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"),
            .init(relativePath: "Embedding.mlmodelc/model.mil", expectedBytes: 78_432, sha256: "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"),
            .init(relativePath: "Embedding.mlmodelc/weights/weight.bin", expectedBytes: 13_412_288, sha256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
            .init(relativePath: "FBank.mlmodelc/analytics/coremldata.bin", expectedBytes: 243, sha256: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
            .init(relativePath: "FBank.mlmodelc/coremldata.bin", expectedBytes: 853, sha256: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
            .init(relativePath: "FBank.mlmodelc/metadata.json", expectedBytes: 3_409, sha256: "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"),
            .init(relativePath: "FBank.mlmodelc/model.mil", expectedBytes: 15_667, sha256: "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"),
            .init(relativePath: "FBank.mlmodelc/weights/weight.bin", expectedBytes: 1_776_896, sha256: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
            .init(relativePath: "PldaRho.mlmodelc/analytics/coremldata.bin", expectedBytes: 243, sha256: "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"),
            .init(relativePath: "PldaRho.mlmodelc/coremldata.bin", expectedBytes: 763, sha256: "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"),
            .init(relativePath: "PldaRho.mlmodelc/metadata.json", expectedBytes: 2_749, sha256: "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"),
            .init(relativePath: "PldaRho.mlmodelc/model.mil", expectedBytes: 7_613, sha256: "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"),
            .init(relativePath: "PldaRho.mlmodelc/weights/weight.bin", expectedBytes: 200_192, sha256: "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"),
            .init(relativePath: "Segmentation.mlmodelc/analytics/coremldata.bin", expectedBytes: 243, sha256: "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
            .init(relativePath: "Segmentation.mlmodelc/coremldata.bin", expectedBytes: 812, sha256: "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
            .init(relativePath: "Segmentation.mlmodelc/metadata.json", expectedBytes: 3_410, sha256: "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"),
            .init(relativePath: "Segmentation.mlmodelc/model.mil", expectedBytes: 43_063, sha256: "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"),
            .init(relativePath: "Segmentation.mlmodelc/weights/weight.bin", expectedBytes: 5_959_360, sha256: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"),
            .init(relativePath: "plda-parameters.json", expectedBytes: 89_416, sha256: "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"),
        ]
    )
}

enum SpeakerDiarizationModelVerificationError: Error, Equatable, Sendable {
    case invalidPath(String)
    case missingFile(String)
    case unexpectedFile(String)
    case invalidFile(String)
}

enum SpeakerDiarizationModelVerifier {
    static func verify(
        directory: URL,
        manifest: SpeakerDiarizationModelManifest = .fluidAudio0155,
        fileManager: FileManager = .default
    ) throws -> Int64 {
        let root = directory.standardizedFileURL
        var expected = Set<String>()
        var allowedDirectories = Set<String>()

        for file in manifest.files {
            guard ManagedAssetVerifier.isSafeRelativePath(file.relativePath),
                  expected.insert(file.relativePath).inserted else {
                throw SpeakerDiarizationModelVerificationError.invalidPath(file.relativePath)
            }
            var parent = NSString(string: file.relativePath).deletingLastPathComponent
            while !parent.isEmpty, parent != "." {
                allowedDirectories.insert(parent)
                parent = NSString(string: parent).deletingLastPathComponent
            }

            let url = root.appendingPathComponent(file.relativePath)
            guard fileManager.fileExists(atPath: url.path) else {
                throw SpeakerDiarizationModelVerificationError.missingFile(file.relativePath)
            }
            do {
                _ = try ManagedAssetVerifier.verifyFile(
                    root: root,
                    relativePath: file.relativePath,
                    expectedBytes: file.expectedBytes,
                    sha256: file.sha256
                )
            } catch {
                throw SpeakerDiarizationModelVerificationError.invalidFile(file.relativePath)
            }
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw SpeakerDiarizationModelVerificationError.invalidFile(".")
        }
        for case let item as URL in enumerator {
            let path = String(item.standardizedFileURL.path.dropFirst(root.path.count + 1))
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw SpeakerDiarizationModelVerificationError.invalidFile(path)
            }
            if values.isDirectory == true {
                guard allowedDirectories.contains(path) else {
                    throw SpeakerDiarizationModelVerificationError.unexpectedFile(path)
                }
            } else if !expected.contains(path) {
                throw SpeakerDiarizationModelVerificationError.unexpectedFile(path)
            }
        }
        return manifest.expectedBytes
    }
}
