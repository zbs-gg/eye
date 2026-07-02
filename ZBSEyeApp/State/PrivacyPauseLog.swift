import Foundation

/// Persisted log of privacy-pause windows ("don't record for 15 minutes"). Recording obviously stops
/// during a pause — but a retroactive importer (browser history) could later backfill visits that
/// happened DURING the pause. So we remember the windows and any such importer filters them out.
/// Windows older than 7 days are pruned (retention default). Stored as flat [startMs, endMs, …] in
/// UserDefaults (Sendable-friendly, no Codable ceremony).
enum PrivacyPauseLog {
    private static let key = "zbseye.privacy.pauseWindows"
    private static let maxAgeMs: Int64 = 7 * 24 * 3600 * 1000

    /// Record a pause window [startMs, endMs]. Called when a privacy pause begins (endMs = planned end).
    static func record(startMs: Int64, endMs: Int64) {
        var flat = load()
        flat.append(startMs); flat.append(endMs)
        save(prune(flat))
    }

    /// Shorten the most recent window's end (user resumed early), so we don't over-exclude.
    static func closeLast(atMs: Int64) {
        var flat = load()
        guard flat.count >= 2 else { return }
        if atMs < flat[flat.count - 1] { flat[flat.count - 1] = atMs }
        save(prune(flat))
    }

    /// Is `tsMs` inside any recorded pause window?
    static func contains(_ tsMs: Int64) -> Bool {
        let flat = load()
        var i = 0
        while i + 1 < flat.count {
            if tsMs >= flat[i] && tsMs <= flat[i + 1] { return true }
            i += 2
        }
        return false
    }

    // MARK: storage

    private static func load() -> [Int64] {
        (UserDefaults.standard.array(forKey: key) as? [NSNumber])?.map { $0.int64Value } ?? []
    }
    private static func save(_ flat: [Int64]) {
        UserDefaults.standard.set(flat.map { NSNumber(value: $0) }, forKey: key)
    }
    private static func prune(_ flat: [Int64]) -> [Int64] {
        // keep windows whose end is within the last 7 days
        guard let newestEnd = stride(from: 1, to: flat.count, by: 2).map({ flat[$0] }).max() else { return flat }
        let cutoff = newestEnd - maxAgeMs
        var out: [Int64] = []
        var i = 0
        while i + 1 < flat.count {
            if flat[i + 1] >= cutoff { out.append(flat[i]); out.append(flat[i + 1]) }
            i += 2
        }
        return out
    }
}
