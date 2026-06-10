import Foundation
import CoreML
import Observation
import Embeddings

/// Статус семантической модели для UI (качается / готова / нет сети). @MainActor-синглтон:
/// пишут акторы загрузки, читает SwiftUI («поиск пока по словам — семантика качается»).
@MainActor
@Observable
final class EmbeddingStatusStore {
    static let shared = EmbeddingStatusStore()
    enum Status: Equatable { case idle, loading, ready, failed }
    private(set) var status: Status = .idle
    fileprivate func set(_ s: Status) { if status != s { status = s } }
}

/// Координатор загрузки e5 — ОДИН на процесс. GUI держит два EmbeddingService (ingest и search,
/// анти head-of-line) — без координатора оба параллельно тянули бы ~300MB с HuggingFace. Здесь
/// загрузки сериализованы актором: первая качает снапшот, вторая берёт из дискового кеша.
/// Кеш — Application Support/Slishu/models (НЕ ~/Documents: тот синкается iCloud → утечка «ноль egress»).
actor E5ModelProvider {
    static let shared = E5ModelProvider()
    private var lastFailureAt: Date?
    /// После провала (оффлайн first-run) не долбим сеть на каждый embed — ретрай не чаще раза в минуту.
    private let retryInterval: TimeInterval = 60

    static func modelsDirectory() -> URL? {
        guard let dir = try? SlishuSupport.directory().appendingPathComponent("models", isDirectory: true)
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        migrateLegacyCacheIfNeeded(to: dir)
        copyBundledModelIfNeeded(to: dir)
        return dir
    }

    /// Модель, упакованная в .app (scripts/build-release.sh кладёт её в Resources/models) → кеш.
    /// Закрывает последний egress: first-run работает целиком оффлайн, ничего не качается.
    private static func copyBundledModelIfNeeded(to base: URL) {
        let repo = "models/intfloat/multilingual-e5-small"
        let fm = FileManager.default
        let target = base.appendingPathComponent(repo, isDirectory: true)
        guard !fm.fileExists(atPath: target.path),
              let bundled = Bundle.main.resourceURL?.appendingPathComponent(repo, isDirectory: true),
              fm.fileExists(atPath: bundled.path) else { return }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: bundled, to: target)
            Log.app.info("e5: модель скопирована из бандла приложения (оффлайн first-run)")
        } catch {
            // не молчим: иначе first-run уйдёт в сеть за 300MB, а лог покажет «оффлайн» (ложь)
            Log.app.error("e5: не удалось скопировать модель из бандла (\(error.localizedDescription)) — будет сетевой fallback")
        }
    }

    /// Раньше HubApi качал в ~/Documents/huggingface (риск iCloud-синка приватной модели + 300MB
    /// перекачки при смене base). Разово переносим ТОЛЬКО НАШ репозиторий модели — общий HF-кеш
    /// могут использовать другие приложения, конфисковывать его целиком нельзя.
    private static func migrateLegacyCacheIfNeeded(to base: URL) {
        let fm = FileManager.default
        let repo = "models/intfloat/multilingual-e5-small"
        let legacy = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/\(repo)", isDirectory: true)
        let target = base.appendingPathComponent(repo, isDirectory: true)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: target.path) else { return }
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: legacy, to: target)
    }

    /// Загрузить bundle (download при первом обращении, далее — из кеша). nil = провал (ретрай позже).
    func loadBundle() async -> XLMRoberta.ModelBundle? {
        if let last = lastFailureAt, Date().timeIntervalSince(last) < retryInterval { return nil }
        await EmbeddingStatusStore.shared.set(.loading)
        do {
            let bundle: XLMRoberta.ModelBundle
            if let base = Self.modelsDirectory() {
                bundle = try await XLMRoberta.loadModelBundle(from: "intfloat/multilingual-e5-small",
                                                              downloadBase: base)
            } else {
                bundle = try await XLMRoberta.loadModelBundle(from: "intfloat/multilingual-e5-small")
            }
            lastFailureAt = nil
            await EmbeddingStatusStore.shared.set(.ready)
            return bundle
        } catch {
            Log.app.error("e5 load failed: \(String(describing: error), privacy: .public)")
            lastFailureAt = Date()
            await EmbeddingStatusStore.shared.set(.failed)
            return nil
        }
    }
}

/// Cross-lingual эмбеддинги (ru↔en) через multilingual-e5-small (384-dim) поверх swift-embeddings
/// (Apple MLTensor, без MLX/Python). Загрузка/кеш — через E5ModelProvider (общий на процесс).
/// e5 требует префиксы "query: " / "passage: ". Векторы L2-нормализованы.
/// Провал загрузки НЕ вечный: повторная попытка при следующем embed (с минутным backoff в провайдере).
actor EmbeddingService {
    private var bundle: XLMRoberta.ModelBundle?
    private var loading = false

    var isReady: Bool { bundle != nil }

    private func ready() async -> XLMRoberta.ModelBundle? {
        if let bundle { return bundle }
        if loading { return nil }   // параллельный embed во время загрузки — не дублируем
        loading = true
        defer { loading = false }
        bundle = await E5ModelProvider.shared.loadBundle()
        return bundle
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
