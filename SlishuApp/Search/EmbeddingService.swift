import Foundation
import NaturalLanguage

/// Локальные эмбеддинги. MVP — системный NLEmbedding (нулевой вес, sentence, 512-dim). Сменный бэкенд
/// (план): multilingual-e5 via MLX для cross-lingual ru→en — следующая итерация. Векторы L2-нормализованы
/// (косинус = скалярное произведение).
actor EmbeddingService {
    private let embedding: NLEmbedding?

    init() {
        embedding = NLEmbedding.sentenceEmbedding(for: .english)   // dim=512, совпадает с vec0 DDL
    }

    /// Возвращает 512-мерный L2-нормализованный вектор или nil (текст пуст / вне словаря модели).
    func embed(_ text: String) -> [Float]? {
        let t = String(text.prefix(2000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let embedding, let v = embedding.vector(for: t) else { return nil }
        var f = v.map { Float($0) }
        var norm: Float = 0
        for x in f { norm += x * x }
        norm = norm.squareRoot()
        if norm > 1e-6 { for i in f.indices { f[i] /= norm } }
        return f
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
