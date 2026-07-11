import Foundation
import MLXLLM
import MLXLMCommon
import Tokenizers

enum LocalModelTestSupport {
    /// Loads only the already verified directory while preserving the Qwen
    /// chat stop token that the registry configuration would otherwise add.
    /// The convenience local-directory overload drops this metadata and can
    /// run until maxTokens even after `<|im_end|>`.
    static func loadContainer(from directory: URL) async throws -> ModelContainer {
        let configuration = ModelConfiguration(
            directory: directory,
            extraEOSTokens: ["<|im_end|>"]
        )
        let resolved = configuration.resolved(
            modelDirectory: directory,
            tokenizerDirectory: directory
        )
        let context = try await LLMModelFactory.shared._load(
            configuration: resolved,
            tokenizerLoader: LocalTokenizerLoader()
        )
        return LLMModelFactory.shared._wrap(context)
    }
}
