import Foundation

enum BuiltInModelFileRole: String, Codable, Sendable {
    case weights
    case weightsIndex
    case modelConfiguration
    case generationConfiguration
    case tokenizer
    case tokenizerConfiguration
    case tokenizerVocabulary
    case tokenizerMerges
    case tokenizerAddedTokens
    case tokenizerSpecialTokens
    case chatTemplate
    case processorConfiguration
    case imagePreprocessorConfiguration
    case videoPreprocessorConfiguration
}

enum BuiltInModelFileRequirement: String, Codable, Sendable {
    case required
    case optional
}

struct BuiltInModelFile: Codable, Sendable, Equatable {
    let relativePath: String
    let sourceURL: URL
    let expectedBytes: Int64
    let sha256: String
    let role: BuiltInModelFileRole
    let requirement: BuiltInModelFileRequirement
}

struct BuiltInModelLicense: Codable, Sendable, Equatable {
    let spdxIdentifier: String
    let displayName: String
    let upstreamModelID: String
    let upstreamLicenseURL: URL
    let immutableProvenanceURL: URL
}

struct BuiltInModelHardwareEnvelope: Codable, Sendable, Equatable {
    let minimumUnifiedMemoryBytes: UInt64
    let maximumUnifiedMemoryBytesExclusive: UInt64?
    let minimumMacOSMajorVersion: Int
    let supportedArchitectures: [String]
    let maximumIncrementalMemoryBytes: UInt64
}

enum BuiltInModelThinkingMode: String, Codable, Sendable {
    case disabled
}

struct BuiltInModelGenerationProfile: Codable, Sendable, Equatable {
    let contextTokenCeiling: Int
    let thinkingMode: BuiltInModelThinkingMode
    let temperature: Double
    let topP: Double
    let benchmarkProtocol: String
}

/// Immutable authority for the downloadable files behind the single
/// `ZBS Eye Local` provider. The runtime must load only a directory that has
/// been verified against one of these complete inventories.
struct BuiltInModelManifest: Codable, Sendable, Equatable, Identifiable {
    static let schemaVersion = 1

    let id: String
    let artifactVersion: Int
    let repositoryID: String
    let revision: String
    let displayName: String
    let modelFamily: String
    let license: BuiltInModelLicense
    let hardware: BuiltInModelHardwareEnvelope
    let generation: BuiltInModelGenerationProfile
    let expectedDownloadBytes: Int64
    let aggregateFingerprintSHA256: String
    let files: [BuiltInModelFile]

    /// Product-downloadable artifacts. Qualification candidates stay outside
    /// this catalog until the exact artifact and hardware pair clears every
    /// release gate.
    static let all = [regular]
    /// Candidates admitted to the U1 offline/runtime/quality harness. Only
    /// manifests in `all` are product-downloadable; a candidate moves there
    /// only after it clears every qualification gate.
    static let qualificationCandidates = [
        smallCandidate,
        qwen35_2BCandidate,
        qwen3_4BCandidate,
        regular,
    ]

    static let smallCandidate = BuiltInModelManifest(
        id: "zbs-eye-local-qwen3-1.7b-4bit-v1",
        artifactVersion: 1,
        repositoryID: "mlx-community/Qwen3-1.7B-4bit",
        revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
        displayName: "Qwen3 1.7B (4-bit)",
        modelFamily: "Qwen3",
        license: BuiltInModelLicense(
            spdxIdentifier: "Apache-2.0",
            displayName: "Apache License 2.0",
            upstreamModelID: "Qwen/Qwen3-1.7B",
            upstreamLicenseURL: URL(string: "https://huggingface.co/Qwen/Qwen3-1.7B/blob/70d244cc86ccca08cf5af4e1e306ecf908b1ad5e/LICENSE")!,
            immutableProvenanceURL: URL(string: "https://huggingface.co/api/models/mlx-community/Qwen3-1.7B-4bit/revision/3b1b1768f8f8cf8351c712464f906e86c2b8269e")!
        ),
        hardware: BuiltInModelHardwareEnvelope(
            minimumUnifiedMemoryBytes: 8 * gibibyte,
            maximumUnifiedMemoryBytesExclusive: 16 * gibibyte,
            minimumMacOSMajorVersion: 15,
            supportedArchitectures: ["arm64"],
            maximumIncrementalMemoryBytes: 2_684_354_560
        ),
        generation: BuiltInModelGenerationProfile(
            contextTokenCeiling: 4_096,
            thinkingMode: .disabled,
            temperature: 0.2,
            topP: 0.95,
            benchmarkProtocol: "local-ai-v1"
        ),
        expectedDownloadBytes: 984_013_244,
        aggregateFingerprintSHA256: "7d23689057cd2dba2a382069967ff22ba1fea787e95d8459527300ee9895c7ed",
        files: files(
            repositoryID: "mlx-community/Qwen3-1.7B-4bit",
            revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
            descriptors: [
                ("added_tokens.json", 707, "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680", .tokenizerAddedTokens),
                ("config.json", 937, "507a6701220524eb8b283425bf0856a9ae4f21f4052e563896ddd668994b1dc7", .modelConfiguration),
                ("merges.txt", 1_671_853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5", .tokenizerMerges),
                ("model.safetensors", 968_080_210, "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f", .weights),
                ("model.safetensors.index.json", 49_731, "1e3058d4ba4b04e4de35b74467725cbef90ff022198404218e48f21adc9cfa15", .weightsIndex),
                ("special_tokens_map.json", 613, "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd", .tokenizerSpecialTokens),
                ("tokenizer.json", 11_422_654, "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4", .tokenizer),
                ("tokenizer_config.json", 9_706, "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0", .tokenizerConfiguration),
                ("vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910", .tokenizerVocabulary),
            ]
        )
    )

    static let qwen35_2BCandidate = BuiltInModelManifest(
        id: "zbs-eye-local-qwen3.5-2b-4bit-v1",
        artifactVersion: 1,
        repositoryID: "mlx-community/Qwen3.5-2B-4bit",
        revision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207",
        displayName: "Qwen3.5 2B (4-bit)",
        modelFamily: "Qwen3.5",
        license: BuiltInModelLicense(
            spdxIdentifier: "Apache-2.0",
            displayName: "Apache License 2.0",
            upstreamModelID: "Qwen/Qwen3.5-2B",
            upstreamLicenseURL: URL(string: "https://huggingface.co/Qwen/Qwen3.5-2B/blob/15852e8c16360a2fea060d615a32b45270f8a8fc/LICENSE")!,
            immutableProvenanceURL: URL(string: "https://huggingface.co/api/models/mlx-community/Qwen3.5-2B-4bit/revision/674aaa7240b91e8012fcad5d791b7dfe5ba90207")!
        ),
        hardware: BuiltInModelHardwareEnvelope(
            minimumUnifiedMemoryBytes: 16 * gibibyte,
            maximumUnifiedMemoryBytesExclusive: nil,
            minimumMacOSMajorVersion: 15,
            supportedArchitectures: ["arm64"],
            maximumIncrementalMemoryBytes: 3_758_096_384
        ),
        generation: BuiltInModelGenerationProfile(
            contextTokenCeiling: 8_192,
            thinkingMode: .disabled,
            temperature: 0.2,
            topP: 0.95,
            benchmarkProtocol: "local-ai-v1"
        ),
        expectedDownloadBytes: 1_749_079_691,
        aggregateFingerprintSHA256: "c96505cb138bd9a345449b0ff253b323d9b4b4542a66fe722894425afe112b93",
        files: files(
            repositoryID: "mlx-community/Qwen3.5-2B-4bit",
            revision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207",
            descriptors: [
                ("chat_template.jinja", 7_755, "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80", .chatTemplate),
                ("config.json", 3_113, "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949", .modelConfiguration),
                ("model.safetensors", 1_722_271_785, "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5", .weights),
                ("model.safetensors.index.json", 81_722, "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d", .weightsIndex),
                ("preprocessor_config.json", 390, "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516", .imagePreprocessorConfiguration),
                ("processor_config.json", 1_300, "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b", .processorConfiguration),
                ("tokenizer.json", 19_989_343, "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4", .tokenizer),
                ("tokenizer_config.json", 1_139, "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182", .tokenizerConfiguration),
                ("video_preprocessor_config.json", 385, "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13", .videoPreprocessorConfiguration),
                ("vocab.json", 6_722_759, "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003", .tokenizerVocabulary),
            ]
        )
    )

    static let qwen3_4BCandidate = BuiltInModelManifest(
        id: "zbs-eye-local-qwen3-4b-instruct-2507-4bit-v1",
        artifactVersion: 1,
        repositoryID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
        displayName: "Qwen3 4B Instruct 2507 (4-bit)",
        modelFamily: "Qwen3",
        license: BuiltInModelLicense(
            spdxIdentifier: "Apache-2.0",
            displayName: "Apache License 2.0",
            upstreamModelID: "Qwen/Qwen3-4B-Instruct-2507",
            upstreamLicenseURL: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507/blob/cdbee75f17c01a7cc42f958dc650907174af0554/LICENSE")!,
            immutableProvenanceURL: URL(string: "https://huggingface.co/api/models/mlx-community/Qwen3-4B-Instruct-2507-4bit/revision/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b")!
        ),
        hardware: BuiltInModelHardwareEnvelope(
            minimumUnifiedMemoryBytes: 16 * gibibyte,
            maximumUnifiedMemoryBytesExclusive: nil,
            minimumMacOSMajorVersion: 15,
            supportedArchitectures: ["arm64"],
            maximumIncrementalMemoryBytes: 5_368_709_120
        ),
        generation: BuiltInModelGenerationProfile(
            contextTokenCeiling: 8_192,
            thinkingMode: .disabled,
            temperature: 0.7,
            topP: 0.8,
            benchmarkProtocol: "local-ai-v2"
        ),
        expectedDownloadBytes: 2_278_969_697,
        aggregateFingerprintSHA256: "ea8b8ac62c667aa89f482cd24ffdb11eee03929dc1d1924273dea39ddb3367b7",
        files: files(
            repositoryID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
            descriptors: [
                ("added_tokens.json", 707, "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680", .tokenizerAddedTokens),
                ("chat_template.jinja", 4_040, "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541", .chatTemplate),
                ("config.json", 938, "574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849", .modelConfiguration),
                ("generation_config.json", 238, "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48", .generationConfiguration),
                ("merges.txt", 1_671_853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5", .tokenizerMerges),
                ("model.safetensors", 2_263_022_417, "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f", .weights),
                ("model.safetensors.index.json", 63_964, "388d811b8b7c2608dd04cce1bcb04a8bf715d19b42790894e6d3427ff429a777", .weightsIndex),
                ("special_tokens_map.json", 613, "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd", .tokenizerSpecialTokens),
                ("tokenizer.json", 11_422_654, "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4", .tokenizer),
                ("tokenizer_config.json", 5_440, "4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9", .tokenizerConfiguration),
                ("vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910", .tokenizerVocabulary),
            ]
        )
    )

    static let regular = BuiltInModelManifest(
        id: "zbs-eye-local-qwen3.5-4b-4bit-v1",
        artifactVersion: 1,
        repositoryID: "mlx-community/Qwen3.5-4B-4bit",
        revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c",
        displayName: "Qwen3.5 4B (4-bit)",
        modelFamily: "Qwen3.5",
        license: BuiltInModelLicense(
            spdxIdentifier: "Apache-2.0",
            displayName: "Apache License 2.0",
            upstreamModelID: "Qwen/Qwen3.5-4B",
            upstreamLicenseURL: URL(string: "https://huggingface.co/Qwen/Qwen3.5-4B/blob/851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a/LICENSE")!,
            immutableProvenanceURL: URL(string: "https://huggingface.co/api/models/mlx-community/Qwen3.5-4B-4bit/revision/0e7ffd5c629ef7719d4cbc04069232580bfa9d9c")!
        ),
        hardware: BuiltInModelHardwareEnvelope(
            minimumUnifiedMemoryBytes: 64 * gibibyte,
            maximumUnifiedMemoryBytesExclusive: 64 * gibibyte + 1,
            minimumMacOSMajorVersion: 15,
            supportedArchitectures: ["arm64"],
            maximumIncrementalMemoryBytes: 5_905_580_032
        ),
        generation: BuiltInModelGenerationProfile(
            contextTokenCeiling: 8_192,
            thinkingMode: .disabled,
            temperature: 0.2,
            topP: 0.95,
            benchmarkProtocol: "local-ai-v9"
        ),
        expectedDownloadBytes: 3_061_129_077,
        aggregateFingerprintSHA256: "0c2207b16c714602a3874f59134a1a70558ce989b7eb4af3764075151e167147",
        files: files(
            repositoryID: "mlx-community/Qwen3.5-4B-4bit",
            revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c",
            descriptors: [
                ("chat_template.jinja", 7_756, "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715", .chatTemplate),
                ("config.json", 3_366, "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa", .modelConfiguration),
                ("model.safetensors", 3_034_300_695, "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db", .weights),
                ("model.safetensors.index.json", 101_944, "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a", .weightsIndex),
                ("preprocessor_config.json", 390, "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516", .imagePreprocessorConfiguration),
                ("processor_config.json", 1_300, "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b", .processorConfiguration),
                ("tokenizer.json", 19_989_343, "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4", .tokenizer),
                ("tokenizer_config.json", 1_139, "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182", .tokenizerConfiguration),
                ("video_preprocessor_config.json", 385, "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13", .videoPreprocessorConfiguration),
                ("vocab.json", 6_722_759, "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003", .tokenizerVocabulary),
            ]
        )
    )

    static func recommended(
        isAppleSilicon: Bool,
        unifiedMemoryBytes: UInt64,
        machineIdentifier: String
    ) -> BuiltInModelManifest? {
        let isBelowQualifiedMaximum = regular.hardware.maximumUnifiedMemoryBytesExclusive.map {
            unifiedMemoryBytes < $0
        } ?? true
        guard
            isAppleSilicon,
            machineIdentifier == "Mac16,5",
            unifiedMemoryBytes >= regular.hardware.minimumUnifiedMemoryBytes,
            isBelowQualifiedMaximum
        else {
            return nil
        }
        return regular
    }

    /// UTF-8 bytes of this exact payload are SHA-256'd to produce
    /// `aggregateFingerprintSHA256`. Keep the format stable across app versions.
    var canonicalFingerprintPayload: String {
        var lines = [
            "schemaVersion=\(Self.schemaVersion)",
            "id=\(id)",
            "artifactVersion=\(artifactVersion)",
            "repositoryID=\(repositoryID)",
            "revision=\(revision)",
            "displayName=\(displayName)",
            "modelFamily=\(modelFamily)",
            "license.spdxIdentifier=\(license.spdxIdentifier)",
            "license.upstreamModelID=\(license.upstreamModelID)",
            "license.upstreamLicenseURL=\(license.upstreamLicenseURL.absoluteString)",
            "license.immutableProvenanceURL=\(license.immutableProvenanceURL.absoluteString)",
            "hardware.minimumUnifiedMemoryBytes=\(hardware.minimumUnifiedMemoryBytes)",
            "hardware.maximumUnifiedMemoryBytesExclusive=\(hardware.maximumUnifiedMemoryBytesExclusive.map(String.init) ?? "none")",
            "hardware.minimumMacOSMajorVersion=\(hardware.minimumMacOSMajorVersion)",
            "hardware.supportedArchitectures=\(hardware.supportedArchitectures.sorted().joined(separator: ","))",
            "hardware.maximumIncrementalMemoryBytes=\(hardware.maximumIncrementalMemoryBytes)",
            "generation.contextTokenCeiling=\(generation.contextTokenCeiling)",
            "generation.thinkingMode=\(generation.thinkingMode.rawValue)",
            "generation.temperature=\(Self.canonicalDecimal(generation.temperature))",
            "generation.topP=\(Self.canonicalDecimal(generation.topP))",
            "generation.benchmarkProtocol=\(generation.benchmarkProtocol)",
            "expectedDownloadBytes=\(expectedDownloadBytes)",
        ]

        lines.append(contentsOf: files.sorted { $0.relativePath < $1.relativePath }.map {
            "file=\($0.relativePath)|\($0.sourceURL.absoluteString)|\($0.expectedBytes)|\($0.sha256)|\($0.role.rawValue)|\($0.requirement.rawValue)"
        })
        return lines.joined(separator: "\n") + "\n"
    }

    private static let gibibyte = UInt64(1_024 * 1_024 * 1_024)

    private static func canonicalDecimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func files(
        repositoryID: String,
        revision: String,
        descriptors: [(String, Int64, String, BuiltInModelFileRole)]
    ) -> [BuiltInModelFile] {
        descriptors.map { relativePath, expectedBytes, sha256, role in
            BuiltInModelFile(
                relativePath: relativePath,
                sourceURL: URL(
                    string: "https://huggingface.co/\(repositoryID)/resolve/\(revision)/\(relativePath)"
                )!,
                expectedBytes: expectedBytes,
                sha256: sha256,
                role: role,
                requirement: .required
            )
        }
    }
}
