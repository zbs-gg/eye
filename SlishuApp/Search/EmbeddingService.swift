import Foundation
import CoreML
import Embeddings

/// Cross-lingual эмбеддинги (ru↔en) через multilingual-e5-small (384-dim) поверх swift-embeddings
/// (Apple MLTensor, без MLX/Python). Модель качается с HuggingFace Hub при первом запуске (~250-470МБ),
/// потом из кеша. e5 требует префиксы "query: " / "passage: ". Векторы L2-нормализованы.
actor EmbeddingService {
    private var bundle: XLMRoberta.ModelBundle?
    private var loadTask: Task<XLMRoberta.ModelBundle?, Never>?
    private(set) var loadFailed = false

    init() {
        loadTask = Task {
            do {
                return try await XLMRoberta.loadModelBundle(from: "intfloat/multilingual-e5-small")
            } catch {
                FileHandle.standardError.write("[embed] e5 load failed: \(error)\n".data(using: .utf8)!)
                return nil
            }
        }
    }

    private func ready() async -> XLMRoberta.ModelBundle? {
        if let bundle { return bundle }
        let b = await loadTask?.value
        bundle = b
        loadFailed = (b == nil)
        return b
    }

    /// Эмбеддинг поискового запроса (префикс "query: ").
    func embed(query text: String) async -> [Float]? { await encode("query: " + text) }
    /// Эмбеддинг индексируемого контента (префикс "passage: ").
    func embed(passage text: String) async -> [Float]? { await encode("passage: " + text) }
    /// Совместимость: по умолчанию контент = passage.
    func embed(_ text: String) async -> [Float]? { await embed(passage: text) }

    private func encode(_ text: String) async -> [Float]? {
        let t = String(text.prefix(1800)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > "passage: ".count, let bundle = await ready() else { return nil }
        // e5 требует MEAN pooling по всем токенам (average_pool с attention-маской). Библиотечный
        // `bundle.encode()` берёт CLS-токен (sequenceOutput[.., 0, ..]) — это верно для классификации,
        // но НЕ для e5-retrieval: схлопывает косинусный зазор (ru↔en падал до ~0.03). Поэтому идём через
        // model напрямую и усредняем сами. Single-text без паддинга → маска вся = 1 → mean по всем токенам.
        guard let tokens = try? bundle.tokenizer.tokenizeText(t, maxLength: 512), !tokens.isEmpty else { return nil }
        let inputIds = MLTensor(shape: [1, tokens.count], scalars: tokens)
        let sequence = bundle.model(inputIds: inputIds).sequenceOutput   // [1, seqLen, 384]
        let pooled = sequence.mean(alongAxes: 1)                         // среднее по токенам → [1, 384]
        let shaped = await pooled.shapedArray(of: Float.self)
        var f = shaped.scalars
        var norm: Float = 0
        for x in f { norm += x * x }
        norm = norm.squareRoot()
        if norm > 1e-6 { for i in f.indices { f[i] /= norm } }
        return f.count == SlishuDatabase.embeddingDim ? f : nil
    }
}

/// Месячный бакет (YYYYMM) для temporal-партиции vec0.
func monthBucket(_ date: Date) -> Int {
    let c = Calendar.current.dateComponents([.year, .month], from: date)
    return (c.year ?? 2026) * 100 + (c.month ?? 1)
}

/// [Float] → Data (little-endian float32) для bind в vec0.
func floatBlob(_ v: [Float]) -> Data {
    v.withUnsafeBufferPointer { Data(buffer: $0) }
}
