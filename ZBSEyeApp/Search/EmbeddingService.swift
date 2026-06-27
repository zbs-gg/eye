import Foundation
import CoreML
import Observation
import Embeddings

/// Status of the semantic model for the UI (downloading / ready / no network). @MainActor singleton:
/// the loading actors write, SwiftUI reads ("search is by words for now — semantics are downloading").
@MainActor
@Observable
final class EmbeddingStatusStore {
    static let shared = EmbeddingStatusStore()
    enum Status: Equatable { case idle, loading, ready, failed }
    private(set) var status: Status = .idle
    fileprivate func set(_ s: Status) { if status != s { status = s } }
}

/// e5 loading coordinator — ONE per process. The GUI holds two EmbeddingServices (ingest and search,
/// anti head-of-line) — without a coordinator both would pull ~300MB from HuggingFace in parallel. Here
/// loads are serialized by an actor: the first downloads the snapshot, the second takes it from the disk cache.
/// Cache — Application Support/ZBS Eye/models (NOT ~/Documents: that syncs to iCloud → a "zero egress" leak).
actor E5ModelProvider {
    static let shared = E5ModelProvider()
    private var lastFailureAt: Date?
    /// After a failure (offline first-run) don't hammer the network on every embed — retry at most once a minute.
    private let retryInterval: TimeInterval = 60

    static func modelsDirectory() -> URL? {
        guard let dir = try? ZBSEyeSupport.directory().appendingPathComponent("models", isDirectory: true)
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        migrateLegacyCacheIfNeeded(to: dir)
        copyBundledModelIfNeeded(to: dir)
        return dir
    }

    /// The model packaged into the .app (scripts/build-release.sh puts it in Resources/models) → cache.
    /// Closes the last egress: first-run works entirely offline, nothing is downloaded.
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
            Log.app.info("e5: model copied from the app bundle (offline first-run)")
        } catch {
            // don't stay silent: otherwise first-run goes to the network for 300MB while the log says "offline" (a lie)
            Log.app.error("e5: failed to copy the model from the bundle (\(error.localizedDescription)) — will fall back to network")
        }
    }

    /// Previously HubApi downloaded into ~/Documents/huggingface (risk of iCloud-syncing a private model + 300MB
    /// re-download on a base change). We move ONLY OUR model repository once — the shared HF cache may be used by
    /// other apps, so we must not confiscate it wholesale.
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

    /// Load the bundle (download on first access, then from cache). nil = failure (retry later).
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

/// Cross-lingual embeddings via multilingual-e5-small (384-dim) on top of swift-embeddings
/// (Apple MLTensor, no MLX/Python). Loading/cache — via E5ModelProvider (shared per process).
/// e5 requires the prefixes "query: " / "passage: ". Vectors are L2-normalized.
/// A load failure is NOT permanent: it retries on the next embed (with a minute backoff in the provider).
actor EmbeddingService {
    private var bundle: XLMRoberta.ModelBundle?
    private var loading = false

    var isReady: Bool { bundle != nil }

    private func ready() async -> XLMRoberta.ModelBundle? {
        if let bundle { return bundle }
        if loading { return nil }   // a parallel embed during loading — don't duplicate
        loading = true
        defer { loading = false }
        bundle = await E5ModelProvider.shared.loadBundle()
        return bundle
    }

    /// Embedding of a search query (prefix "query: ").
    func embed(query text: String) async -> [Float]? { await encode("query: " + text) }
    /// Embedding of indexed content (prefix "passage: ").
    func embed(passage text: String) async -> [Float]? { await encode("passage: " + text) }
    /// Compatibility: by default content = passage.
    func embed(_ text: String) async -> [Float]? { await embed(passage: text) }

    private func encode(_ text: String) async -> [Float]? {
        let t = String(text.prefix(1800)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > "passage: ".count, let bundle = await ready() else { return nil }
        // e5 requires MEAN pooling over all tokens (average_pool with an attention mask). The library's
        // `bundle.encode()` takes the CLS token (sequenceOutput[.., 0, ..]) — correct for classification,
        // but NOT for e5 retrieval: it collapses the cosine gap (cross-lingual dropped to ~0.03). So we go
        // through the model directly and average ourselves. Single text without padding → mask all = 1 → mean over all tokens.
        guard let tokens = try? bundle.tokenizer.tokenizeText(t, maxLength: 512), !tokens.isEmpty else { return nil }
        let inputIds = MLTensor(shape: [1, tokens.count], scalars: tokens)
        let sequence = bundle.model(inputIds: inputIds).sequenceOutput   // [1, seqLen, 384]
        let pooled = sequence.mean(alongAxes: 1)                         // mean over tokens → [1, 384]
        let shaped = await pooled.shapedArray(of: Float.self)
        var f = shaped.scalars
        var norm: Float = 0
        for x in f { norm += x * x }
        norm = norm.squareRoot()
        if norm > 1e-6 { for i in f.indices { f[i] /= norm } }
        return f.count == ZBSEyeDatabase.embeddingDim ? f : nil
    }
}

/// Monthly bucket (YYYYMM) for the vec0 temporal partition.
func monthBucket(_ date: Date) -> Int {
    let c = Calendar.current.dateComponents([.year, .month], from: date)
    return (c.year ?? 2026) * 100 + (c.month ?? 1)
}

/// [Float] → Data (little-endian float32) for binding into vec0.
func floatBlob(_ v: [Float]) -> Data {
    v.withUnsafeBufferPointer { Data(buffer: $0) }
}
