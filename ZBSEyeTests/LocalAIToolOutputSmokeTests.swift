import Foundation
import MLXLMCommon
import XCTest

final class LocalAIToolOutputSmokeTests: XCTestCase {
    func testQwenCanUseTheNoSideEffectAnswerTool() async throws {
        let bundle = Bundle(for: LocalAIToolOutputSmokeTests.self)
        let enabled = ProcessInfo.processInfo.environment["ZBS_EYE_LOCAL_AI_TOOL_PROBE"]
            ?? bundle.object(forInfoDictionaryKey: "ZBSEyeLocalAIToolProbe") as? String
        guard enabled == "1" else { throw XCTSkip("Tool-output runtime probe is opt-in") }
        let path = ProcessInfo.processInfo.environment["ZBS_EYE_MODEL_DIR"]
            ?? bundle.object(forInfoDictionaryKey: "ZBSEyeModelDirectory") as? String
        guard let path, !path.isEmpty else {
            XCTFail("Tool-output runtime probe requires ZBS_EYE_MODEL_DIR")
            return
        }

        let container = try await LocalModelTestSupport.loadContainer(
            from: URL(fileURLWithPath: path, isDirectory: true)
        )
        let session = ChatSession(
            container,
            instructions: """
            Answer only from the supplied fragment. You must call emit_zbs_eye_answer exactly once.
            Do not write normal prose before or after the call. Put citations only in source arrays.
            """,
            generateParameters: GenerateParameters(
                maxTokens: 256,
                temperature: 0.2,
                topP: 0.95,
                prefillStepSize: 256,
                seed: 42
            ),
            additionalContext: ["enable_thinking": false],
            tools: [LocalAIAnswerToolContract.schema]
        )

        var chunks = ""
        var calls: [ToolCall] = []
        for try await event in session.streamDetails(
            to: "Question: When is the review and who owns it?\n[1] Review is Friday at 14:00. Owner: Maya."
        ) {
            switch event {
            case .chunk(let chunk): chunks += chunk
            case .toolCall(let call): calls.append(call)
            case .info: break
            }
        }

        print("TOOL PROBE chunks=\(chunks)")
        print("TOOL PROBE calls=\(calls)")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.function.name, "emit_zbs_eye_answer")
        XCTAssertTrue(chunks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let data = try JSONEncoder().encode(calls[0].function.arguments)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "supported")
        XCTAssertEqual(object["item1_sources"] as? [String], ["[1]"])
    }

}
