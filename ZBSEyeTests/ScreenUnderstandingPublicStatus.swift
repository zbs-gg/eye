import Foundation

struct ScreenUnderstandingPublicStatus: Codable, Sendable, Equatable {
    struct Method: Codable, Sendable, Equatable {
        var id: String
        var status: String
        var evidence: String
        var privateCorpusAccess: Bool
    }

    var protocolID: String
    var date: String
    var methods: [Method]
    var qualityConclusion: String
    var qualityReason: String
    var containsPersonalCorpus: Bool
    var containsCaseMaterial: Bool

    static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func validate() throws {
        let allowedIDs = Set([
            "metadata-ax-ocr", "apple-vision", "deterministic-hybrid",
            "florence-2-base", "smolvlm-256m-instruct", "lfm2-vl-450m",
            "fastvlm-0.5b", "smolvlm2-256m-video-instruct", "omniparser-v2",
        ])
        let allowedStatuses = Set([
            "mapping-inconclusive", "security-unsupported",
        ])
        let builtInIDs = Set([
            "metadata-ax-ocr", "apple-vision", "deterministic-hybrid",
        ])
        guard protocolID == "screen-understanding-v1",
              Set(methods.map(\.id)) == allowedIDs,
              methods.count == allowedIDs.count,
              methods.allSatisfy({ allowedStatuses.contains($0.status) }),
              methods.allSatisfy({ method in
                  method.privateCorpusAccess == builtInIDs.contains(method.id)
              }),
              !containsPersonalCorpus,
              !containsCaseMaterial,
              qualityConclusion == "inconclusive",
              !qualityReason.isEmpty else {
            throw ScreenUnderstandingProtocolError.invalid("Unsafe or incomplete public status")
        }
        let serialized = try String(decoding: JSONEncoder().encode(self), as: UTF8.self)
        let forbiddenFragments = [
            "/Users/", "/Volumes/", "file://", "sk-", "BEGIN PRIVATE KEY", "caseID",
        ]
        guard !forbiddenFragments.contains(where: serialized.contains) else {
            throw ScreenUnderstandingProtocolError.invalid("Public status contains private material")
        }
    }
}
