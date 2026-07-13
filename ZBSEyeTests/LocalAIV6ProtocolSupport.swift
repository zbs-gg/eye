import CryptoKit
import Foundation

enum LocalAIV6ProtocolSupport {
    static let protocolID = "local-ai-v6"
    static let revision = 6
    static let variants = ["production", "perturbation-1", "perturbation-2"]

    static func evaluationSeeds<Input: Encodable>(
        promptContract: String,
        caseID: String,
        input: Input
    ) throws -> [(variant: String, seed: UInt64)] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let inputJSON = String(decoding: try encoder.encode(input), as: UTF8.self)
        let canonical = (
            "\(protocolID)\n\(revision)\n\(promptContract)\n\(caseID)\n\(inputJSON)"
        ).precomposedStringWithCanonicalMapping
        return variants.enumerated().map { index, variant in
            let material = index == 0
                ? canonical
                : "\(canonical)\nperturbation:\(index)"
            let digest = SHA256.hash(data: Data(material.utf8))
            let seed = digest.prefix(8).reduce(UInt64.zero) {
                ($0 << 8) | UInt64($1)
            }
            return (variant, seed)
        }
    }
}
