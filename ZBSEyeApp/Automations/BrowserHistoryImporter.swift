import Foundation
import GRDB

/// Pulls real browser history (URL + title + visit time) from each browser's own local database into
/// `browser_visits`. Fills a gap in screen capture: Dia/Arc don't expose the URL via Accessibility, so
/// `screen_captures.browserUrl` is empty for them — the browser records every visit itself.
///
/// 100% on-device: reads a CONSISTENT snapshot of the browser's local DB (SQLite backup API from a
/// read-only source; falls back to a file copy that is integrity-checked before use), writes only into
/// our own DB. Nothing leaves the machine. Incremental via a STABLE per-source cursor (the DB path) in
/// UserDefaults + a UNIQUE(browser,ts,url) index. Never backfills a privacy-pause window
/// (`PrivacyPauseLog`). Supported: Chromium family (Dia/Arc/Chrome/Edge/Brave — `urls`/`visits`, µs
/// since 1601) and Safari (`history_items`/`history_visits`, secs since 2001; needs Full Disk Access,
/// reported clearly if missing).
actor BrowserHistoryImporter {
    private let db: ZBSEyeDatabase
    private var running = false
    init(db: ZBSEyeDatabase) { self.db = db }

    /// Result of a run. `errors` carries human-readable per-source problems (e.g. Safari FDA missing).
    struct Report: Sendable { var imported = 0; var sources = 0; var errors: [String] = [] }

    private enum Format { case chromium, safari }
    private struct Source: Sendable { let bundleId: String; let name: String; let baseDir: String; let format: Format }
    private enum ImportError: Error { case tornSnapshot }

    private static func sources() -> [Source] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSup = home + "/Library/Application Support"
        return [
            .init(bundleId: "company.thebrowser.dia",  name: "Dia",   baseDir: appSup + "/Dia/User Data", format: .chromium),
            .init(bundleId: "company.thebrowser.arc",  name: "Arc",   baseDir: appSup + "/Arc/User Data", format: .chromium),
            .init(bundleId: "com.google.Chrome",       name: "Chrome", baseDir: appSup + "/Google/Chrome", format: .chromium),
            .init(bundleId: "com.microsoft.edgemac",   name: "Edge",  baseDir: appSup + "/Microsoft Edge", format: .chromium),
            .init(bundleId: "com.brave.Browser",       name: "Brave", baseDir: appSup + "/BraveSoftware/Brave-Browser", format: .chromium),
            .init(bundleId: "com.apple.Safari",        name: "Safari", baseDir: home + "/Library/Safari/History.db", format: .safari),
        ]
    }

    func run() async throws -> Report {
        guard !running else { return Report() }
        running = true
        defer { running = false }

        var report = Report()
        for src in Self.sources() {
            for dbPath in Self.historyDBs(for: src) {
                if Task.isCancelled { return report }
                do {
                    report.imported += try await importOne(src: src, dbPath: dbPath)
                    report.sources += 1
                } catch {
                    let ns = error as NSError
                    if src.format == .safari && (ns.code == 257 || ns.domain == NSCocoaErrorDomain) {
                        report.errors.append("Safari history unavailable — grant Full Disk Access in System Settings → Privacy.")
                    } else {
                        report.errors.append("\(src.name): \(error.localizedDescription)")
                    }
                    Log.app.info("browser-history: skip \(dbPath) — \(error.localizedDescription)")
                }
            }
        }
        if report.imported > 0 { Log.app.info("browser-history import: +\(report.imported) visits from \(report.sources) source(s)") }
        return report
    }

    private static func historyDBs(for src: Source) -> [String] {
        let fm = FileManager.default
        switch src.format {
        case .safari:
            return fm.fileExists(atPath: src.baseDir) ? [src.baseDir] : []
        case .chromium:
            guard let profiles = try? fm.contentsOfDirectory(atPath: src.baseDir) else { return [] }
            return profiles.map { src.baseDir + "/" + $0 + "/History" }.filter { fm.fileExists(atPath: $0) }
        }
    }

    private func importOne(src: Source, dbPath: String) async throws -> Int {
        // STABLE cursor key: the DB path itself (Swift hashValue is per-process-random — do not use it).
        let cursorKey = "zbseye.browserhist.cursor:" + URL(fileURLWithPath: dbPath).standardizedFileURL.path
        let cursorStr = UserDefaults.standard.string(forKey: cursorKey) ?? "0"

        let (queue, tmpDir) = try openSnapshot(dbPath)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        struct Raw: Sendable { let nativeTs: Double; let tsMs: Int64; let url: String; let title: String?; let vc: Int? }

        // Read a consistent batch, keeping the RAW max native ts so the cursor advances even when every
        // row is filtered out (privacy/non-http) — otherwise a source could stall forever.
        let (raws, rawMaxNative): ([Raw], Double) = try await queue.read { dbc in
            let rows: [Row]
            switch src.format {
            case .chromium:
                let cur = Int64(cursorStr) ?? 0            // µs since 1601 — Int64 (exceeds Double's exact range)
                rows = try Row.fetchAll(dbc, sql: """
                    SELECT v.visit_time AS vt, u.url AS url, u.title AS title, u.visit_count AS vc
                    FROM visits v JOIN urls u ON u.id = v.url
                    WHERE v.visit_time > ? ORDER BY v.visit_time LIMIT 5000
                    """, arguments: [cur])
            case .safari:
                let cur = Double(cursorStr) ?? 0           // seconds since 2001 — Double (fractional)
                rows = try Row.fetchAll(dbc, sql: """
                    SELECT hv.visit_time AS vt, hi.url AS url, hv.title AS title, hi.visit_count AS vc
                    FROM history_visits hv JOIN history_items hi ON hi.id = hv.history_item
                    WHERE hv.visit_time > ? ORDER BY hv.visit_time LIMIT 5000
                    """, arguments: [cur])
            }
            var out: [Raw] = []
            var maxNative = Double(cursorStr) ?? 0
            for r in rows {
                let native: Double
                let tsMs: Int64
                switch src.format {
                case .chromium:
                    let micros: Int64 = r["vt"]
                    native = Double(micros)
                    tsMs = (micros - 11_644_473_600_000_000) / 1000
                case .safari:
                    let secs: Double = r["vt"]
                    native = secs
                    tsMs = Int64((secs + 978_307_200) * 1000)
                }
                maxNative = max(maxNative, native)
                guard let url: String = r["url"], url.hasPrefix("http"), tsMs > 0 else { continue }
                out.append(Raw(nativeTs: native, tsMs: tsMs, url: url, title: r["title"], vc: r["vc"]))
            }
            return (out, maxNative)
        }

        // Drop anything inside a privacy-pause window (never backfill what the user paused).
        let visits = raws.filter { !PrivacyPauseLog.contains($0.tsMs) }

        var inserted = 0
        if !visits.isEmpty {
            inserted = try await db.pool.write { dbc -> Int in
                var n = 0
                for v in visits {
                    try dbc.execute(sql: """
                        INSERT OR IGNORE INTO browser_visits (ts, url, host, title, browser, visitCount)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [v.tsMs, v.url, DayActivityRepository.hostFromURL(v.url),
                                         v.title, src.bundleId, v.vc])
                    n += dbc.changesCount                 // actual inserts (OR IGNORE skips dups)
                }
                return n
            }
        }

        // Advance the cursor to the raw max (even if nothing was inserted) — no stall, no dup-loop.
        // Chromium stays integer-exact; Safari keeps fractional precision as a Double string.
        if rawMaxNative > (Double(cursorStr) ?? 0) {
            let newCursor = (src.format == .chromium) ? String(Int64(rawMaxNative)) : String(rawMaxNative)
            UserDefaults.standard.set(newCursor, forKey: cursorKey)
        }
        return inserted
    }

    /// A consistent snapshot of the browser DB. Preferred: SQLite backup API from a read-only source
    /// (transactionally consistent even under concurrent writes). Fallback (some browsers hold an
    /// exclusive lock that blocks the read-only open): copy the files + `PRAGMA integrity_check`, and
    /// refuse a torn copy so the cursor doesn't advance over bad data (retried next run).
    private func openSnapshot(_ path: String) throws -> (queue: DatabaseQueue, tmpDir: URL) {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("zbseye-bh-" + UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dest = tmpDir.appendingPathComponent("snap.db")
        do {
            var cfg = Configuration(); cfg.readonly = true
            let src = try DatabaseQueue(path: path, configuration: cfg)
            let dst = try DatabaseQueue(path: dest.path)
            try src.backup(to: dst)
            return (dst, tmpDir)
        } catch {
            try? fm.removeItem(at: dest)
            try fm.copyItem(atPath: path, toPath: dest.path)
            for ext in ["-wal", "-shm"] where fm.fileExists(atPath: path + ext) {
                try? fm.copyItem(atPath: path + ext, toPath: dest.path + ext)
            }
            let q = try DatabaseQueue(path: dest.path)
            let ok = try q.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
            guard ok == "ok" else { throw ImportError.tornSnapshot }
            return (q, tmpDir)
        }
    }
}
