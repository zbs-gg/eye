import CryptoKit
import Foundation
import XCTest

final class LocalAIEvalProtocolTests: XCTestCase {
    private struct V6SeedLockInput: Codable {
        let question: String
        let evidence: [String]
    }
    private struct V7SeedLockInput: Codable {
        let question: String
        let evidence: [String]
    }
    private struct V8SeedLockInput: Codable {
        let question: String
        let evidence: [String]
    }
    private struct V9SeedLockInput: Codable {
        let question: String
        let evidence: [String]
    }
    private struct ProtocolDocument: Decodable {
        struct ProtocolIdentity: Decodable {
            let id: String
            let revision: Int
            let status: String
        }

        struct Fixture: Decodable {
            let path: String
            let language: String
            let caseCount: Int
            let sha256: String

            enum CodingKeys: String, CodingKey {
                case path, language, sha256
                case caseCount = "case_count"
            }
        }

        struct Generation: Decodable {
            let thinking: Bool
            let temperature: Double
            let topP: Double
            let topK: Int
            let presencePenalty: Double?

            enum CodingKeys: String, CodingKey {
                case thinking, temperature
                case topP = "top_p"
                case topK = "top_k"
                case presencePenalty = "presence_penalty"
            }
        }

        let `protocol`: ProtocolIdentity
        let fixtureFiles: [Fixture]
        let generation: Generation

        enum CodingKeys: String, CodingKey {
            case `protocol`, generation
            case fixtureFiles = "fixture_files"
        }
    }

    func testV2ProtocolAndFixturesAreLockedToTheExecutedConfiguration() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals", isDirectory: true)
        let data = try Data(contentsOf: root.appendingPathComponent("local-ai-v2.json"))
        let document = try JSONDecoder().decode(ProtocolDocument.self, from: data)

        XCTAssertEqual(document.protocol.id, "local-ai-v2")
        XCTAssertEqual(document.protocol.revision, 2)
        XCTAssertEqual(document.protocol.status, "provisional")
        XCTAssertFalse(document.generation.thinking)
        XCTAssertEqual(document.generation.temperature, 0.7)
        XCTAssertEqual(document.generation.topP, 0.8)
        XCTAssertEqual(document.generation.topK, 20)
        XCTAssertEqual(document.generation.presencePenalty, 1.5)
        XCTAssertEqual(Set(document.fixtureFiles.map(\.language)), ["en", "ru"])

        for fixture in document.fixtureFiles {
            let fixtureData = try Data(contentsOf: root.appendingPathComponent(fixture.path))
            let digest = SHA256.hash(data: fixtureData)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(digest, fixture.sha256, fixture.path)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
            )
            let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
            XCTAssertEqual(cases.count, fixture.caseCount, fixture.path)
            XCTAssertTrue(cases.allSatisfy { item in
                guard let consumer = item["consumer"] as? String,
                      let contract = item["prompt_contract"] as? String else { return false }
                return contract == (consumer == "ask" ? "ask-v2" : "insights-v2")
            })
        }
    }

    func testV3ProtocolAndFixturesLockTheToolCallConfiguration() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals", isDirectory: true)
        let data = try Data(contentsOf: root.appendingPathComponent("local-ai-v3.json"))
        let document = try JSONDecoder().decode(ProtocolDocument.self, from: data)

        XCTAssertEqual(document.protocol.id, "local-ai-v3")
        XCTAssertEqual(document.protocol.revision, 3)
        XCTAssertEqual(document.protocol.status, "provisional")
        XCTAssertFalse(document.generation.thinking)
        XCTAssertEqual(document.generation.temperature, 0.2)
        XCTAssertEqual(document.generation.topP, 0.95)
        XCTAssertEqual(document.generation.topK, 0)
        XCTAssertNil(document.generation.presencePenalty)

        for fixture in document.fixtureFiles {
            let fixtureData = try Data(contentsOf: root.appendingPathComponent(fixture.path))
            let digest = SHA256.hash(data: fixtureData)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(digest, fixture.sha256, fixture.path)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
            )
            let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
            XCTAssertEqual(cases.count, fixture.caseCount, fixture.path)
            XCTAssertTrue(cases.allSatisfy { item in
                guard let consumer = item["consumer"] as? String,
                      let contract = item["prompt_contract"] as? String else { return false }
                return contract == (consumer == "ask" ? "ask-v3" : "insights-v3")
            })
        }
    }

    func testV4ProtocolAndFixturesLockCanonicalSourcesAndLocalizedLedger() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals", isDirectory: true)
        let data = try Data(contentsOf: root.appendingPathComponent("local-ai-v4.json"))
        let document = try JSONDecoder().decode(ProtocolDocument.self, from: data)

        XCTAssertEqual(document.protocol.id, "local-ai-v4")
        XCTAssertEqual(document.protocol.revision, 4)
        XCTAssertEqual(document.protocol.status, "provisional")
        XCTAssertFalse(document.generation.thinking)
        XCTAssertEqual(document.generation.temperature, 0.2)
        XCTAssertEqual(document.generation.topP, 0.95)
        XCTAssertEqual(document.generation.topK, 0)
        XCTAssertNil(document.generation.presencePenalty)

        for fixture in document.fixtureFiles {
            let fixtureData = try Data(contentsOf: root.appendingPathComponent(fixture.path))
            let digest = SHA256.hash(data: fixtureData)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(digest, fixture.sha256, fixture.path)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
            )
            let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
            XCTAssertEqual(cases.count, fixture.caseCount, fixture.path)
            XCTAssertTrue(cases.allSatisfy { item in
                guard let consumer = item["consumer"] as? String,
                      let contract = item["prompt_contract"] as? String else { return false }
                return contract == (consumer == "ask" ? "ask-v4" : "insights-v4")
            })
        }
    }

    func testV5ProtocolAndFixturesLockMLXBridgeCanonicalization() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals", isDirectory: true)
        let data = try Data(contentsOf: root.appendingPathComponent("local-ai-v5.json"))
        let document = try JSONDecoder().decode(ProtocolDocument.self, from: data)

        XCTAssertEqual(document.protocol.id, "local-ai-v5")
        XCTAssertEqual(document.protocol.revision, 5)
        XCTAssertEqual(document.protocol.status, "provisional")
        XCTAssertFalse(document.generation.thinking)
        XCTAssertEqual(document.generation.temperature, 0.2)
        XCTAssertEqual(document.generation.topP, 0.95)
        XCTAssertEqual(document.generation.topK, 0)
        XCTAssertNil(document.generation.presencePenalty)

        for fixture in document.fixtureFiles {
            let fixtureData = try Data(contentsOf: root.appendingPathComponent(fixture.path))
            let digest = SHA256.hash(data: fixtureData)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(digest, fixture.sha256, fixture.path)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
            )
            let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
            XCTAssertEqual(cases.count, fixture.caseCount, fixture.path)
            XCTAssertTrue(cases.allSatisfy { item in
                guard let consumer = item["consumer"] as? String,
                      let contract = item["prompt_contract"] as? String else { return false }
                return contract == (consumer == "ask" ? "ask-v5" : "insights-v5")
            })
        }
    }

    func testV6ReleaseProtocolLocksFourConsumersUniqueCasesHashesAndThresholds() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals", isDirectory: true)
        let protocolData = try Data(contentsOf: root.appendingPathComponent("local-ai-v6.json"))
        let protocolObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: protocolData) as? [String: Any]
        )
        let identity = try XCTUnwrap(protocolObject["protocol"] as? [String: Any])
        XCTAssertEqual(identity["id"] as? String, "local-ai-v6")
        XCTAssertEqual(identity["revision"] as? Int, 6)
        XCTAssertEqual(identity["status"] as? String, "release-candidate")
        let provenance = try XCTUnwrap(identity["provenance"] as? [String: Any])
        XCTAssertEqual(provenance["contains_user_history"] as? Bool, false)
        XCTAssertEqual(provenance["contains_secrets"] as? Bool, false)

        let thresholds = try XCTUnwrap(protocolObject["thresholds"] as? [String: Any])
        XCTAssertEqual(thresholds["stable_case_pass_rate_min"] as? Double, 0.90)
        XCTAssertEqual(thresholds["stable_per_language_case_pass_rate_min"] as? Double, 0.85)
        XCTAssertEqual(thresholds["stable_per_consumer_case_pass_rate_min"] as? Double, 0.85)
        XCTAssertEqual(thresholds["parser_acceptance_rate_min"] as? Double, 0.95)
        XCTAssertEqual(thresholds["unsupported_refusal_rate"] as? Double, 1.0)
        XCTAssertEqual(thresholds["attempted_seed_variants_per_case"] as? Int, 3)
        XCTAssertEqual(thresholds["minimum_cases_per_language"] as? Int, 30)

        let generation = try XCTUnwrap(protocolObject["generation"] as? [String: Any])
        XCTAssertEqual(generation["thinking"] as? Bool, false)
        XCTAssertEqual(generation["temperature"] as? Double, 0.2)
        XCTAssertEqual(generation["top_p"] as? Double, 0.95)
        XCTAssertEqual(generation["top_k"] as? Int, 0)
        XCTAssertTrue(generation["presence_penalty"] is NSNull)
        XCTAssertEqual(generation["prefill_step_size"] as? Int, 256)
        XCTAssertEqual(generation["retries"] as? Int, 0)
        XCTAssertEqual(generation["attempted_seed_variants_per_case"] as? Int, 3)
        let maximumOutputTokens = try XCTUnwrap(
            generation["max_output_tokens"] as? [String: Int]
        )
        XCTAssertEqual(maximumOutputTokens, [
            "ask": 800,
            "insights": 400,
            "summary": 800,
            "label": 60,
        ])

        let promptContracts = try XCTUnwrap(
            protocolObject["prompt_contracts"] as? [String: [String: String]]
        )
        XCTAssertEqual(
            promptContracts["insights-production-v6"]?["prompt_version"],
            "daily-insights-v3"
        )
        XCTAssertEqual(
            promptContracts["summary-production-v6"]?["prompt_version"],
            "daily-summary-v2"
        )
        XCTAssertEqual(
            promptContracts["label-production-v6"]?["prompt_version"],
            "block-label-v2"
        )

        let distribution = try XCTUnwrap(
            protocolObject["case_distribution"] as? [String: Any]
        )
        XCTAssertEqual(distribution["total"] as? Int, 64)
        let declaredPerLanguage = try XCTUnwrap(
            distribution["per_language"] as? [String: Int]
        )
        XCTAssertEqual(declaredPerLanguage, ["en": 32, "ru": 32])
        let declaredPerConsumer = try XCTUnwrap(
            distribution["per_language_and_consumer"] as? [String: [String: Int]]
        )
        let declaredRefusals = try XCTUnwrap(
            distribution["must_refuse_per_language"] as? [String: Int]
        )
        XCTAssertEqual(declaredRefusals, ["en": 4, "ru": 4])

        let expectedHashes = [
            "en": "458695ff0e8c1a69c8d1cc7c3633bc73d4e9bc47f82a3560a504a4b884b628bc",
            "ru": "c0b20ea80a7ae27f98b97825717d4165ed1b0c97eaddc18b290f237b95beb7c8",
        ]
        let fixtures = try XCTUnwrap(protocolObject["fixture_files"] as? [[String: Any]])
        XCTAssertEqual(Set(fixtures.compactMap { $0["language"] as? String }), ["en", "ru"])
        var allIDs = Set<String>()
        var allCanonicalInputs = Set<Data>()
        let expectedConsumers = Set(["ask", "insights", "summary", "label"])

        for fixture in fixtures {
            let language = try XCTUnwrap(fixture["language"] as? String)
            let path = try XCTUnwrap(fixture["path"] as? String)
            let fixtureData = try Data(contentsOf: root.appendingPathComponent(path))
            let digest = SHA256.hash(data: fixtureData).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(fixture["sha256"] as? String, digest, path)
            XCTAssertEqual(digest, expectedHashes[language], path)

            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
            )
            XCTAssertEqual(object["schema_id"] as? String, "gg.zbs.eye.eval-fixtures/v6")
            XCTAssertEqual(object["protocol_id"] as? String, "local-ai-v6")
            XCTAssertEqual(object["language"] as? String, language)
            XCTAssertEqual(object["contains_user_history"] as? Bool, false)
            XCTAssertEqual(object["contains_secrets"] as? Bool, false)
            let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
            XCTAssertEqual(cases.count, fixture["case_count"] as? Int)
            XCTAssertEqual(cases.count, 32)
            XCTAssertGreaterThanOrEqual(cases.count, 30)
            XCTAssertEqual(declaredPerLanguage[language], cases.count)

            let grouped = Dictionary(grouping: cases) { $0["consumer"] as? String ?? "" }
            XCTAssertEqual(Set(grouped.keys), expectedConsumers)
            for consumer in expectedConsumers {
                XCTAssertEqual(grouped[consumer]?.count, 8, "\(language)/\(consumer)")
                XCTAssertEqual(
                    declaredPerConsumer[language]?[consumer],
                    grouped[consumer]?.count,
                    "declared \(language)/\(consumer)"
                )
            }
            let refusalCount = cases.filter {
                (($0["expect"] as? [String: Any])?["must_refuse"] as? Bool) == true
            }.count
            XCTAssertEqual(refusalCount, 4)
            XCTAssertEqual(
                declaredRefusals[language],
                refusalCount,
                "declared refusals for \(language)"
            )

            for item in cases {
                let id = try XCTUnwrap(item["id"] as? String)
                XCTAssertTrue(allIDs.insert(id).inserted, "duplicate case id \(id)")
                let consumer = try XCTUnwrap(item["consumer"] as? String)
                let contract = try XCTUnwrap(item["prompt_contract"] as? String)
                XCTAssertEqual(contract, "\(consumer)-production-v6")
                let input = try XCTUnwrap(item["input"] as? [String: Any])
                let canonical = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
                XCTAssertTrue(
                    allCanonicalInputs.insert(canonical).inserted,
                    "duplicate canonical input \(id)"
                )
            }
        }
        XCTAssertEqual(allIDs.count, 64)
        XCTAssertEqual(allCanonicalInputs.count, 64)
    }

    func testV6SeedDerivationLocksThreeExactVariants() throws {
        let first = try LocalAIV6ProtocolSupport.evaluationSeeds(
            promptContract: "ask-production-v6",
            caseID: "seed-lock",
            input: V6SeedLockInput(question: "Where?", evidence: ["Synthetic"])
        )
        let second = try LocalAIV6ProtocolSupport.evaluationSeeds(
            promptContract: "ask-production-v6",
            caseID: "seed-lock",
            input: V6SeedLockInput(question: "Where?", evidence: ["Synthetic"])
        )
        XCTAssertEqual(first.map(\.variant), [
            "production", "perturbation-1", "perturbation-2",
        ])
        XCTAssertEqual(first.map(\.seed), [
            1_333_098_743_419_446_907,
            2_862_527_444_429_066_886,
            16_799_780_932_276_129_901,
        ])
        XCTAssertEqual(first.map(\.seed), second.map(\.seed))
        XCTAssertEqual(Set(first.map(\.seed)).count, 3)
    }

    func testV7ReleaseProtocolLocksSeparatedProductionChannelsAndCopiedFixtures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals", isDirectory: true)
        let protocolData = try Data(contentsOf: root.appendingPathComponent("local-ai-v7.json"))
        let protocolObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: protocolData) as? [String: Any]
        )
        let identity = try XCTUnwrap(protocolObject["protocol"] as? [String: Any])
        XCTAssertEqual(identity["id"] as? String, "local-ai-v7")
        XCTAssertEqual(identity["revision"] as? Int, 7)
        XCTAssertEqual(identity["status"] as? String, "release-candidate")
        XCTAssertEqual(identity["supersedes"] as? String, "local-ai-v6")
        let provenance = try XCTUnwrap(identity["provenance"] as? [String: Any])
        XCTAssertEqual(provenance["contains_user_history"] as? Bool, false)
        XCTAssertEqual(provenance["contains_secrets"] as? Bool, false)
        XCTAssertTrue(
            (provenance["stability"] as? String)?.contains("requires revision 8") == true
        )

        let construction = try XCTUnwrap(
            protocolObject["production_request_construction"] as? [String: Any]
        )
        XCTAssertEqual(
            construction["no_bypass"] as? String,
            "Every physical generation uses the captured production LLMRequest; test-only prompt copies or overlays are forbidden."
        )
        let channels = try XCTUnwrap(protocolObject["separated_channels"] as? [String: Any])
        XCTAssertTrue((channels["built_in_local"] as? String)?.contains("unconditional") == true)
        XCTAssertTrue((channels["external"] as? String)?.contains("no function") == true)

        let promptContracts = try XCTUnwrap(
            protocolObject["prompt_contracts"] as? [String: [String: String]]
        )
        XCTAssertEqual(
            promptContracts["ask-production-v7"]?["prompt_version"],
            "AskService built-in native-tool production request"
        )
        XCTAssertEqual(
            promptContracts["insights-production-v7"]?["prompt_version"],
            "daily-insights-v4"
        )
        XCTAssertEqual(
            promptContracts["summary-production-v7"]?["prompt_version"],
            "daily-summary-v3"
        )
        XCTAssertEqual(
            promptContracts["label-production-v7"]?["prompt_version"],
            "block-label-v3"
        )

        let thresholds = try XCTUnwrap(protocolObject["thresholds"] as? [String: Any])
        XCTAssertEqual(thresholds["stable_case_pass_rate_min"] as? Double, 0.90)
        XCTAssertEqual(thresholds["stable_per_language_case_pass_rate_min"] as? Double, 0.85)
        XCTAssertEqual(thresholds["stable_per_consumer_case_pass_rate_min"] as? Double, 0.85)
        XCTAssertEqual(thresholds["parser_acceptance_rate_min"] as? Double, 0.95)
        XCTAssertEqual(thresholds["unsupported_refusal_rate"] as? Double, 1.0)
        XCTAssertEqual(thresholds["attempted_seed_variants_per_case"] as? Int, 3)

        let expectedHashes = [
            "en": "5dd1171ed00403b2045a3619472431b847e04b2e1c43100ddcf6e5b53dde628a",
            "ru": "12a03ab2811c2d3d2abf700861bd3904d9c90b7d71977a575babab73b0d8160f",
        ]
        let fixtures = try XCTUnwrap(protocolObject["fixture_files"] as? [[String: Any]])
        XCTAssertEqual(Set(fixtures.compactMap { $0["language"] as? String }), ["en", "ru"])
        var allIDs = Set<String>()
        var allCanonicalInputs = Set<Data>()
        let expectedConsumers = Set(["ask", "insights", "summary", "label"])
        for fixture in fixtures {
            let language = try XCTUnwrap(fixture["language"] as? String)
            let path = try XCTUnwrap(fixture["path"] as? String)
            let fixtureData = try Data(contentsOf: root.appendingPathComponent(path))
            let digest = SHA256.hash(data: fixtureData)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(digest, expectedHashes[language], path)
            XCTAssertEqual(fixture["sha256"] as? String, digest, path)

            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
            )
            XCTAssertEqual(object["schema_id"] as? String, "gg.zbs.eye.eval-fixtures/v7")
            XCTAssertEqual(object["protocol_id"] as? String, "local-ai-v7")
            XCTAssertEqual(object["language"] as? String, language)
            XCTAssertEqual(object["contains_user_history"] as? Bool, false)
            XCTAssertEqual(object["contains_secrets"] as? Bool, false)
            let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
            XCTAssertEqual(cases.count, 32)
            XCTAssertEqual(cases.count, fixture["case_count"] as? Int)
            let grouped = Dictionary(grouping: cases) { $0["consumer"] as? String ?? "" }
            XCTAssertEqual(Set(grouped.keys), expectedConsumers)
            for consumer in expectedConsumers {
                XCTAssertEqual(grouped[consumer]?.count, 8, "\(language)/\(consumer)")
            }
            XCTAssertEqual(cases.filter {
                (($0["expect"] as? [String: Any])?["must_refuse"] as? Bool) == true
            }.count, 4)

            for item in cases {
                let id = try XCTUnwrap(item["id"] as? String)
                XCTAssertTrue(allIDs.insert(id).inserted, "duplicate case id \(id)")
                let consumer = try XCTUnwrap(item["consumer"] as? String)
                XCTAssertEqual(
                    item["prompt_contract"] as? String,
                    "\(consumer)-production-v7"
                )
                let input = try XCTUnwrap(item["input"] as? [String: Any])
                let canonical = try JSONSerialization.data(
                    withJSONObject: input,
                    options: [.sortedKeys]
                )
                XCTAssertTrue(
                    allCanonicalInputs.insert(canonical).inserted,
                    "duplicate canonical input \(id)"
                )
            }
        }
        XCTAssertEqual(allIDs.count, 64)
        XCTAssertEqual(allCanonicalInputs.count, 64)
    }

    func testV7SeedDerivationLocksThreeExactVariants() throws {
        let first = try LocalAIV7ProtocolSupport.evaluationSeeds(
            promptContract: "ask-production-v7",
            caseID: "seed-lock",
            input: V7SeedLockInput(question: "Where?", evidence: ["Synthetic"])
        )
        let second = try LocalAIV7ProtocolSupport.evaluationSeeds(
            promptContract: "ask-production-v7",
            caseID: "seed-lock",
            input: V7SeedLockInput(question: "Where?", evidence: ["Synthetic"])
        )
        XCTAssertEqual(first.map(\.variant), [
            "production", "perturbation-1", "perturbation-2",
        ])
        XCTAssertEqual(first.map(\.seed), [
            5_162_714_158_318_182_695,
            15_861_764_515_382_401_518,
            1_135_839_882_252_550_325,
        ])
        XCTAssertEqual(first.map(\.seed), second.map(\.seed))
        XCTAssertEqual(Set(first.map(\.seed)).count, 3)
    }

    func testV8ProtocolLocksLabelBudgetAndCoverageMetadataRule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals", isDirectory: true)
        let protocolData = try Data(contentsOf: root.appendingPathComponent("local-ai-v8.json"))
        let protocolObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: protocolData) as? [String: Any]
        )
        let identity = try XCTUnwrap(protocolObject["protocol"] as? [String: Any])
        XCTAssertEqual(identity["id"] as? String, "local-ai-v8")
        XCTAssertEqual(identity["revision"] as? Int, 8)
        XCTAssertEqual(identity["status"] as? String, "release-candidate")
        XCTAssertEqual(identity["supersedes"] as? String, "local-ai-v7")
        XCTAssertTrue(
            (identity["change_reason"] as? String)?.contains("60-token") == true
        )
        XCTAssertTrue(
            (identity["change_reason"] as? String)?.contains("coverage metadata") == true
        )
        let provenance = try XCTUnwrap(identity["provenance"] as? [String: Any])
        XCTAssertTrue(
            (provenance["stability"] as? String)?.contains("requires revision 9") == true
        )

        let promptContracts = try XCTUnwrap(
            protocolObject["prompt_contracts"] as? [String: [String: String]]
        )
        XCTAssertEqual(
            promptContracts["ask-production-v8"]?["prompt_version"],
            "AskService built-in native-tool production request"
        )
        XCTAssertEqual(
            promptContracts["insights-production-v8"]?["prompt_version"],
            "daily-insights-v4"
        )
        XCTAssertEqual(
            promptContracts["summary-production-v8"]?["prompt_version"],
            "daily-summary-v4"
        )
        XCTAssertEqual(
            promptContracts["label-production-v8"]?["prompt_version"],
            "block-label-v4"
        )

        let generation = try XCTUnwrap(protocolObject["generation"] as? [String: Any])
        let outputCaps = try XCTUnwrap(
            generation["max_output_tokens"] as? [String: Int]
        )
        XCTAssertEqual(outputCaps["label"], 160)
        XCTAssertEqual(outputCaps["summary"], 800)

        let bounded = try XCTUnwrap(
            protocolObject["bounded_preflight"] as? [String: Any]
        )
        XCTAssertEqual(bounded["release_qualification"] as? Bool, false)
        XCTAssertEqual(bounded["case_count"] as? Int, 8)
        XCTAssertEqual(bounded["attempt_count"] as? Int, 24)
        XCTAssertEqual(bounded["parser_acceptance_required"] as? Double, 1.0)
        XCTAssertEqual(bounded["stable_case_pass_required"] as? Double, 1.0)
        XCTAssertEqual(
            bounded["case_ids"] as? [String],
            LocalAIV8ProbeSupport.caseIDs
        )

        let expectedHashes = [
            "en": "2cd084dfb825fc60bf65add6a703550cf56e5ca00cef5278c62a6ef32e6426d7",
            "ru": "268863b6e40bb077ef3fe3e7682cc0c0443ea24619750d49fd2495c1e1cbb262",
        ]
        let fixtures = try XCTUnwrap(protocolObject["fixture_files"] as? [[String: Any]])
        XCTAssertEqual(Set(fixtures.compactMap { $0["language"] as? String }), ["en", "ru"])
        var allIDs = Set<String>()
        var allCanonicalInputs = Set<Data>()
        let expectedConsumers = Set(["ask", "insights", "summary", "label"])
        for fixture in fixtures {
            let language = try XCTUnwrap(fixture["language"] as? String)
            let path = try XCTUnwrap(fixture["path"] as? String)
            let fixtureData = try Data(contentsOf: root.appendingPathComponent(path))
            let digest = SHA256.hash(data: fixtureData)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(digest, expectedHashes[language], path)
            XCTAssertEqual(fixture["sha256"] as? String, digest, path)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
            )
            XCTAssertEqual(object["schema_id"] as? String, "gg.zbs.eye.eval-fixtures/v8")
            XCTAssertEqual(object["protocol_id"] as? String, "local-ai-v8")
            let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
            XCTAssertEqual(cases.count, 32)
            XCTAssertEqual(cases.count, fixture["case_count"] as? Int)
            let grouped = Dictionary(grouping: cases) { $0["consumer"] as? String ?? "" }
            XCTAssertEqual(Set(grouped.keys), expectedConsumers)
            for consumer in expectedConsumers {
                XCTAssertEqual(grouped[consumer]?.count, 8, "\(language)/\(consumer)")
            }
            XCTAssertEqual(cases.filter {
                (($0["expect"] as? [String: Any])?["must_refuse"] as? Bool) == true
            }.count, 4)
            for item in cases {
                let id = try XCTUnwrap(item["id"] as? String)
                XCTAssertTrue(allIDs.insert(id).inserted, "duplicate case id \(id)")
                let consumer = try XCTUnwrap(item["consumer"] as? String)
                XCTAssertEqual(
                    item["prompt_contract"] as? String,
                    "\(consumer)-production-v8"
                )
                if consumer == "summary" {
                    let expect = try XCTUnwrap(item["expect"] as? [String: Any])
                    XCTAssertEqual(expect["allowed_numbers"] as? [String], [])
                }
                let input = try XCTUnwrap(item["input"] as? [String: Any])
                let canonical = try JSONSerialization.data(
                    withJSONObject: input,
                    options: [.sortedKeys]
                )
                XCTAssertTrue(
                    allCanonicalInputs.insert(canonical).inserted,
                    "duplicate canonical input \(id)"
                )
            }
        }
        XCTAssertEqual(allIDs.count, 64)
        XCTAssertEqual(allCanonicalInputs.count, 64)
    }

    func testV8SeedDerivationLocksThreeExactVariants() throws {
        let first = try LocalAIV8ProtocolSupport.evaluationSeeds(
            promptContract: "ask-production-v8",
            caseID: "seed-lock",
            input: V8SeedLockInput(question: "Where?", evidence: ["Synthetic"])
        )
        XCTAssertEqual(first.map(\.variant), [
            "production", "perturbation-1", "perturbation-2",
        ])
        XCTAssertEqual(first.map(\.seed), [
            7_425_019_249_797_243_738,
            3_652_216_277_440_538_193,
            16_668_199_795_506_479_082,
        ])
        XCTAssertEqual(Set(first.map(\.seed)).count, 3)
    }

    func testV7BoundedProbeLocksExactlyOneCasePerLanguageAndConsumer() throws {
        XCTAssertEqual(LocalAIV7ProbeSupport.caseIDs, [
            "v6-en-ask-01",
            "v6-en-insights-01",
            "v6-en-summary-01",
            "v6-en-label-01",
            "v6-ru-ask-01",
            "v6-ru-insights-01",
            "v6-ru-summary-01",
            "v6-ru-label-01",
        ])

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals/fixtures", isDirectory: true)
        var selected: [(language: String, consumer: String, id: String)] = []
        for language in ["en", "ru"] {
            let data = try Data(
                contentsOf: root.appendingPathComponent("local-ai-v7-\(language).json")
            )
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
            selected += try cases.compactMap { item in
                let id = try XCTUnwrap(item["id"] as? String)
                guard LocalAIV7ProbeSupport.caseIDSet.contains(id) else { return nil }
                return (
                    language,
                    try XCTUnwrap(item["consumer"] as? String),
                    id
                )
            }
        }

        XCTAssertEqual(selected.count, 8)
        XCTAssertEqual(Set(selected.map(\.id)), LocalAIV7ProbeSupport.caseIDSet)
        let distribution = Dictionary(grouping: selected) {
            "\($0.language)/\($0.consumer)"
        }.mapValues(\.count)
        XCTAssertEqual(distribution, [
            "en/ask": 1,
            "en/insights": 1,
            "en/summary": 1,
            "en/label": 1,
            "ru/ask": 1,
            "ru/insights": 1,
            "ru/summary": 1,
            "ru/label": 1,
        ])
    }

    func testV9ProtocolLocksDecoderPrefixPurposeSchemasAndCopiedFixtures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals", isDirectory: true)
        let protocolPath = root.appendingPathComponent("local-ai-v9.json")
        guard FileManager.default.fileExists(atPath: protocolPath.path) else {
            XCTFail("local-ai-v9.json must exist before the physical V9 preflight")
            return
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: protocolPath))
                as? [String: Any]
        )
        let identity = try XCTUnwrap(object["protocol"] as? [String: Any])
        XCTAssertEqual(identity["id"] as? String, "local-ai-v9")
        XCTAssertEqual(identity["revision"] as? Int, 9)
        XCTAssertEqual(identity["status"] as? String, "release-candidate")
        XCTAssertEqual(identity["supersedes"] as? String, "local-ai-v8")
        XCTAssertTrue(
            (identity["change_reason"] as? String)?.contains("91.6667%") == true
        )
        XCTAssertTrue(
            (identity["change_reason"] as? String)?.contains("bare JSON") == true
        )
        let provenance = try XCTUnwrap(identity["provenance"] as? [String: Any])
        XCTAssertTrue(
            (provenance["stability"] as? String)?.contains("requires revision 10") == true
        )

        let predecessor = try XCTUnwrap(
            object["negative_predecessor"] as? [String: Any]
        )
        XCTAssertEqual(predecessor["protocol_id"] as? String, "local-ai-v8")
        XCTAssertEqual(predecessor["release_qualification"] as? Bool, false)
        XCTAssertEqual(
            predecessor["summary_path"] as? String,
            "local-ai-v8-negative-probe.md"
        )
        XCTAssertEqual(
            predecessor["raw_report_sha256"] as? String,
            "f481844c5054ff7695c32df2d564e6f78478c15f131f15a7444a2df5ad6466f9"
        )
        let negativeRecord = try String(
            contentsOf: root.appendingPathComponent("local-ai-v8-negative-probe.md"),
            encoding: .utf8
        )
        XCTAssertTrue(negativeRecord.contains("Stable cases passed: `7 / 8`"))
        XCTAssertTrue(negativeRecord.contains("Parser acceptance: `22 / 24`"))

        let construction = try XCTUnwrap(
            object["production_request_construction"] as? [String: Any]
        )
        XCTAssertTrue(
            (construction["no_bypass"] as? String)?.contains(
                "same decoder-prefix generation helper as production"
            ) == true
        )
        let channel = try XCTUnwrap(object["structured_channel"] as? [String: Any])
        XCTAssertEqual(
            channel["forced_decoder_prefix"] as? String,
            "<tool_call>\n<function=emit_zbs_eye_answer>\n"
        )
        XCTAssertEqual(
            channel["forced_decoder_prefix"] as? String,
            MLXForcedNativeToolPrefix.text
        )
        XCTAssertEqual(
            channel["schema_factory"] as? String,
            "LocalAIAnswerToolContract.schema(for:)"
        )
        XCTAssertTrue(
            (channel["prefix_budget_accounting"] as? String)?.contains(
                "consume the existing maximum-output-token budget"
            ) == true
        )
        XCTAssertEqual(channel["repair"] as? String, "none")
        XCTAssertEqual(channel["function_call_count"] as? Int, 1)
        XCTAssertTrue(
            (channel["legacy_schema"] as? String)?.contains("V3-V8") == true
        )

        let schemas = try XCTUnwrap(
            channel["schema_by_purpose"] as? [String: [String: Any]]
        )
        func assertSchema(
            _ purpose: String,
            properties: Set<String>,
            statuses: [String]
        ) throws {
            let schema = try XCTUnwrap(schemas[purpose])
            XCTAssertEqual(Set(schema["properties"] as? [String] ?? []), properties)
            XCTAssertEqual(schema["status_enum"] as? [String], statuses)
            XCTAssertEqual(
                schema["required"] as? [String],
                ["status", "item1_text", "item1_sources"]
            )
            XCTAssertEqual(schema["additional_properties"] as? Bool, false)
        }
        try assertSchema(
            "ask",
            properties: [
                "status", "item1_text", "item1_sources", "item2_text",
                "item2_sources", "next_search",
            ],
            statuses: ["supported", "uncertain", "not_found"]
        )
        try assertSchema(
            "insights",
            properties: [
                "status", "item1_text", "item1_sources", "item2_text",
                "item2_sources", "item3_text", "item3_sources",
            ],
            statuses: ["supported", "conflict", "insufficient"]
        )
        for purpose in ["summary", "label"] {
            try assertSchema(
                purpose,
                properties: ["status", "item1_text", "item1_sources"],
                statuses: ["supported"]
            )
        }

        let promptContracts = try XCTUnwrap(
            object["prompt_contracts"] as? [String: [String: String]]
        )
        XCTAssertEqual(
            promptContracts["ask-production-v9"]?["prompt_version"],
            "AskService built-in native-tool production request"
        )
        XCTAssertEqual(
            promptContracts["insights-production-v9"]?["prompt_version"],
            "daily-insights-v4"
        )
        XCTAssertEqual(
            promptContracts["summary-production-v9"]?["prompt_version"],
            "daily-summary-v4"
        )
        XCTAssertEqual(
            promptContracts["label-production-v9"]?["prompt_version"],
            "block-label-v4"
        )

        let generation = try XCTUnwrap(object["generation"] as? [String: Any])
        let outputCaps = try XCTUnwrap(
            generation["max_output_tokens"] as? [String: Int]
        )
        XCTAssertEqual(outputCaps, [
            "ask": 800,
            "insights": 400,
            "summary": 800,
            "label": 160,
        ])
        XCTAssertEqual(generation["attempted_seed_variants_per_case"] as? Int, 3)
        XCTAssertEqual(generation["retries"] as? Int, 0)

        let thresholds = try XCTUnwrap(object["thresholds"] as? [String: Any])
        XCTAssertEqual(thresholds["stable_case_pass_rate_min"] as? Double, 0.90)
        XCTAssertEqual(thresholds["stable_per_language_case_pass_rate_min"] as? Double, 0.85)
        XCTAssertEqual(thresholds["stable_per_consumer_case_pass_rate_min"] as? Double, 0.85)
        XCTAssertEqual(thresholds["parser_acceptance_rate_min"] as? Double, 0.95)
        XCTAssertEqual(thresholds["unsupported_refusal_rate"] as? Double, 1.0)

        let bounded = try XCTUnwrap(object["bounded_preflight"] as? [String: Any])
        XCTAssertEqual(bounded["release_qualification"] as? Bool, false)
        XCTAssertEqual(bounded["case_count"] as? Int, 8)
        XCTAssertEqual(bounded["attempt_count"] as? Int, 24)
        XCTAssertEqual(bounded["parser_acceptance_required"] as? Double, 1.0)
        XCTAssertEqual(bounded["stable_case_pass_required"] as? Double, 1.0)
        XCTAssertEqual(bounded["case_ids"] as? [String], LocalAIV9ProbeSupport.caseIDs)

        let expectedHashes = [
            "en": "bea40e3cc940da560e1f3a0d820330c3456a0e057a380e1387ca18476df4bedc",
            "ru": "3130f254dcd750ebb7da45dfadba9a9ff41dd9da2ba1cf75d963fb8f046de1e9",
        ]
        let fixtures = try XCTUnwrap(object["fixture_files"] as? [[String: Any]])
        XCTAssertEqual(Set(fixtures.compactMap { $0["language"] as? String }), ["en", "ru"])
        var allIDs = Set<String>()
        var allCanonicalInputs = Set<Data>()
        let expectedConsumers = Set(["ask", "insights", "summary", "label"])
        for fixture in fixtures {
            let language = try XCTUnwrap(fixture["language"] as? String)
            let path = try XCTUnwrap(fixture["path"] as? String)
            let fixtureData = try Data(contentsOf: root.appendingPathComponent(path))
            let digest = SHA256.hash(data: fixtureData)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(digest, expectedHashes[language], path)
            XCTAssertEqual(fixture["sha256"] as? String, digest, path)
            let fixtureObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
            )
            XCTAssertEqual(
                fixtureObject["schema_id"] as? String,
                "gg.zbs.eye.eval-fixtures/v9"
            )
            XCTAssertEqual(fixtureObject["protocol_id"] as? String, "local-ai-v9")
            let cases = try XCTUnwrap(fixtureObject["cases"] as? [[String: Any]])
            XCTAssertEqual(cases.count, 32)
            XCTAssertEqual(cases.count, fixture["case_count"] as? Int)
            let grouped = Dictionary(grouping: cases) { $0["consumer"] as? String ?? "" }
            XCTAssertEqual(Set(grouped.keys), expectedConsumers)
            for consumer in expectedConsumers {
                XCTAssertEqual(grouped[consumer]?.count, 8, "\(language)/\(consumer)")
            }
            XCTAssertEqual(cases.filter {
                (($0["expect"] as? [String: Any])?["must_refuse"] as? Bool) == true
            }.count, 4)

            let v8Data = try Data(
                contentsOf: root.appendingPathComponent(
                    "fixtures/local-ai-v8-\(language).json"
                )
            )
            let v8Object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: v8Data) as? [String: Any]
            )
            let v8Cases = try XCTUnwrap(v8Object["cases"] as? [[String: Any]])
            XCTAssertEqual(cases.count, v8Cases.count)
            for (item, predecessor) in zip(cases, v8Cases) {
                let id = try XCTUnwrap(item["id"] as? String)
                XCTAssertEqual(id, predecessor["id"] as? String)
                XCTAssertEqual(item["consumer"] as? String, predecessor["consumer"] as? String)
                XCTAssertEqual(item["category"] as? String, predecessor["category"] as? String)
                XCTAssertEqual(item["prompt_contract"] as? String, "\(item["consumer"] as? String ?? "")-production-v9")
                XCTAssertTrue(allIDs.insert(id).inserted, "duplicate case id \(id)")

                let input = try XCTUnwrap(item["input"] as? [String: Any])
                let predecessorInput = try XCTUnwrap(
                    predecessor["input"] as? [String: Any]
                )
                let canonical = try JSONSerialization.data(
                    withJSONObject: input,
                    options: [.sortedKeys]
                )
                let predecessorCanonical = try JSONSerialization.data(
                    withJSONObject: predecessorInput,
                    options: [.sortedKeys]
                )
                XCTAssertEqual(canonical, predecessorCanonical, id)
                XCTAssertTrue(
                    allCanonicalInputs.insert(canonical).inserted,
                    "duplicate canonical input \(id)"
                )

                let expectation = try XCTUnwrap(item["expect"] as? [String: Any])
                let predecessorExpectation = try XCTUnwrap(
                    predecessor["expect"] as? [String: Any]
                )
                XCTAssertEqual(
                    try JSONSerialization.data(
                        withJSONObject: expectation,
                        options: [.sortedKeys]
                    ),
                    try JSONSerialization.data(
                        withJSONObject: predecessorExpectation,
                        options: [.sortedKeys]
                    ),
                    id
                )
                if item["consumer"] as? String == "summary" {
                    XCTAssertEqual(expectation["allowed_numbers"] as? [String], [])
                }
            }
        }
        XCTAssertEqual(allIDs.count, 64)
        XCTAssertEqual(allCanonicalInputs.count, 64)
    }

    func testV9SeedDerivationLocksThreeFreshExactVariants() throws {
        let first = try LocalAIV9ProtocolSupport.evaluationSeeds(
            promptContract: "ask-production-v9",
            caseID: "seed-lock",
            input: V9SeedLockInput(question: "Where?", evidence: ["Synthetic"])
        )
        XCTAssertEqual(first.map(\.variant), [
            "production", "perturbation-1", "perturbation-2",
        ])
        XCTAssertEqual(first.map(\.seed), [
            11_234_545_759_681_570_157,
            7_785_015_539_353_374_885,
            1_865_797_427_135_820_409,
        ])
        XCTAssertEqual(Set(first.map(\.seed)).count, 3)
    }

    func testQualityGateScriptTargetsV9WithoutRemovingV6V7V8FixtureCoverage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-local-ai.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains(
            "-only-testing:ZBSEyeTests/LocalAIQualityGateV9Tests"
        ))
        XCTAssertTrue(script.contains(
            "require_suite_ran_without_skip \"LocalAIQualityGateV9Tests\""
        ))
        XCTAssertTrue(script.contains("Local AI V9 quality gate green"))
        XCTAssertTrue(script.contains(
            #""MLXLocalRuntimeDriverTests""#
        ))
        XCTAssertTrue(script.contains(
            #"TEST_FILTERS+=("-only-testing:ZBSEyeTests/${suite}")"#
        ))
        XCTAssertFalse(script.contains(
            "TEST_FILTERS=(\"-only-testing:ZBSEyeTests/LocalAIQualityGateV6Tests\")"
        ))
        XCTAssertFalse(script.contains(
            "TEST_FILTERS=(\"-only-testing:ZBSEyeTests/LocalAIQualityGateV7Tests"
        ))
        XCTAssertFalse(script.contains(
            "TEST_FILTERS=(\"-only-testing:ZBSEyeTests/LocalAIQualityGateV8Tests"
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "ZBSEyeTests/LocalAIQualityGateV6Tests.swift"
            ).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "ZBSEyeTests/LocalAIQualityGateV7Tests.swift"
            ).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "ZBSEyeTests/LocalAIQualityGateV8Tests.swift"
            ).path
        ))
    }

    func testQualityProbeScriptAndReportStaySeparateFromTheReleaseGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-local-ai.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("--quality-probe"))
        XCTAssertTrue(script.contains("RUN_QUALITY_PROBE"))
        XCTAssertTrue(script.contains("ZBS_EYE_LOCAL_AI_QUALITY_PROBE"))
        XCTAssertTrue(script.contains(
            "LocalAIQualityGateV9Tests/testBoundedEnglishRussianFourConsumerProbe"
        ))
        XCTAssertTrue(script.contains("Local AI V9 bounded quality probe green"))

        let project = try String(
            contentsOf: root.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("ZBS_EYE_LOCAL_AI_QUALITY_PROBE: \"\""))
        let info = try String(
            contentsOf: root.appendingPathComponent("ZBSEyeTests/Info.plist"),
            encoding: .utf8
        )
        XCTAssertTrue(info.contains("<key>ZBSEyeLocalAIQualityProbe</key>"))
        XCTAssertTrue(info.contains("$(ZBS_EYE_LOCAL_AI_QUALITY_PROBE)"))

        let harness = try String(
            contentsOf: root.appendingPathComponent(
                "ZBSEyeTests/LocalAIQualityGateV9Tests.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(harness.contains("local-ai-v9-probe-"))
        XCTAssertTrue(harness.contains("releaseQualification: false"))
        XCTAssertTrue(harness.contains("stableCaseCount: 8"))
        XCTAssertTrue(harness.contains("attemptCount: 24"))
        XCTAssertTrue(harness.contains("MLXLocalStructuredGeneration.start"))
        XCTAssertTrue(harness.contains("LocalAIAnswerToolContract.schema(for:"))
        XCTAssertTrue(harness.contains("qualificationSeed: seed"))
        XCTAssertFalse(harness.contains("ChatSession("))
    }

    func testPerformanceOfflineGuardsSurviveTheXCTestProcessBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: root.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let info = try String(
            contentsOf: root.appendingPathComponent("ZBSEyeTests/Info.plist"),
            encoding: .utf8
        )
        let harness = try String(
            contentsOf: root.appendingPathComponent(
                "ZBSEyeTests/MLXRuntimeQualificationTests.swift"
            ),
            encoding: .utf8
        )

        for (setting, plistKey, value) in [
            ("HF_HUB_OFFLINE", "ZBSEyeHFHubOffline", "1"),
            ("TRANSFORMERS_OFFLINE", "ZBSEyeTransformersOffline", "1"),
            ("ZBS_EYE_ALLOW_MODEL_DOWNLOADS", "ZBSEyeAllowModelDownloads", "0"),
        ] {
            XCTAssertTrue(project.contains("\(setting): \"\(value)\""))
            XCTAssertTrue(info.contains("<key>\(plistKey)</key>"))
            XCTAssertTrue(info.contains("$(\(setting))"))
            XCTAssertTrue(harness.contains("plist: \"\(plistKey)\""))
        }
    }
}
