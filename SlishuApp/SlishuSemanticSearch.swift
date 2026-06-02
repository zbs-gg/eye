import Foundation
import NaturalLanguage

public final class SlishuSemanticSearcher {
    public static let shared = SlishuSemanticSearcher()
    
    private let englishEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    private let russianEmbedding = NLEmbedding.sentenceEmbedding(for: NLLanguage("ru"))
    
    private init() {
        print("🧠 Инициализирован SlishuSemanticSearcher. Доступность моделей: Английская: \(englishEmbedding != nil), Русская: \(russianEmbedding != nil)")
    }
    
    /// Генерирует вектор эмбеддинга для переданной строки
    public func getEmbedding(for text: String) -> [Float]? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }
        
        // Автоматически определяем язык для выбора оптимальной модели
        let languageRecognizer = NLLanguageRecognizer()
        languageRecognizer.processString(cleanText)
        let language = languageRecognizer.dominantLanguage
        
        // Приоритетная модель на основе определенного языка
        let embeddingModel = (language == .russian) ? (russianEmbedding ?? englishEmbedding) : (englishEmbedding ?? russianEmbedding)
        
        guard let model = embeddingModel else {
            return nil
        }
        
        // NLEmbedding возвращает массив Double, приводим к Float для компактности хранения в БД
        if let doubleVector = model.vector(for: cleanText) {
            return doubleVector.map { Float($0) }
        }
        
        return nil
    }
    
    /// Быстрое вычисление косинусного сходства двух векторов в Swift
    public static func cosineSimilarity(_ v1: [Float], _ v2: [Float]) -> Float {
        guard v1.count == v2.count, !v1.isEmpty else { return 0.0 }
        var dotProduct: Float = 0.0
        var magnitude1: Float = 0.0
        var magnitude2: Float = 0.0
        
        for i in 0..<v1.count {
            let x = v1[i]
            let y = v2[i]
            dotProduct += x * y
            magnitude1 += x * x
            magnitude2 += y * y
        }
        
        guard magnitude1 > 0.0, magnitude2 > 0.0 else { return 0.0 }
        return dotProduct / (sqrt(magnitude1) * sqrt(magnitude2))
    }
}
