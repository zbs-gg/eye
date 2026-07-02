import Foundation
import GRDB

/// Pulls real browser history (URL + title + visit time) from each browser's own local database into
/// `browser_visits`. This fills a gap in screen capture: Dia/Arc don't expose the URL via Accessibility,
/// so `screen_captures.browserUrl` is empty for them — but the browser records every visit itself.
///
/// 100% on-device: we only READ the browser's local DB (a WAL-safe copy, never the live file) and write
/// into our own DB. Nothing leaves the machine. Incremental: a per-source cursor (last native visit time)
/// persists in UserDefaults, so re-runs never re-import or duplicate (also guarded by a UNIQUE index).
///
/// Supported: Chromium family (Dia, Arc, Chrome, Edge, Brave — `urls`/`visits`, time = µs since 1601) and
/// Safari (`history_items`/`history_visits`, time = seconds since 2001; needs Full Disk Access, fails
/// gracefully if not granted).
actor BrowserHistoryImporter {
    private let db: ZBSEyeDatabase
    private var running = false
    init(db: ZBSEyeDatabase) { self.db = db }

    struct Report: Sendable { var imported = 0; var sources = 0 }

    private enum Format { case chromium, safari }
    private struct Source: Sendable { let bundleId: String; let baseDir: String; let format: Format }

    /// Where each browser keeps its history DB(s). Chromium browsers have per-profile `History` files
    /// under the base dir; we scan for them. Safari has a single History.db.
    private static func sources() -> [Source] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSup = home + "/Library/Application Support"
        return [
            .init(bundleId: "company.thebrowser.dia",  baseDir: appSup + "/Dia/User Data", format: .chromium),
            .init(bundleId: "company.thebrowser.arc",  baseDir: appSup + "/Arc/User Data", format: .chromium),
            .init(bundleId: "com.google.Chrome",       baseDir: appSup + "/Google/Chrome", format: .chromium),
            .init(bundleId: "com.microsoft.edgemac",   baseDir: appSup + "/Microsoft Edge", format: .chromium),
            .init(bundleId: "com.brave.Browser",       baseDir: appSup + "/BraveSoftware/Brave-Browser", format: .chromium),
            .init(bundleId: "com.apple.Safari",        baseDir: home + "/Library/Safari/History.db", format: .safari),
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
                    let n = try await importOne(bundleId: src.bundleId, format: src.format, dbPath: dbPath)
                    if n > 0 { report.imported += n }
                    report.sources += 1
                } catch {
                    Log.app.info("browser-history: skip \(dbPath) — \(error.localizedDescription)")
                }
            }
        }
        if report.imported > 0 { Log.app.info("browser-history import: +\(report.imported) visits from \(report.sources) source(s)") }
        return report
    }

    /// The actual History DB paths for a source (Chromium: one per profile; Safari: the single file).
    private static func historyDBs(for src: Source) -> [String] {
        let fm = FileManager.default
        switch src.format {
        case .safari:
            return fm.fileExists(atPath: src.baseDir) ? [src.baseDir] : []
        case .chromium:
            guard let profiles = try? fm.contentsOfDirectory(atPath: src.baseDir) else { return [] }
            return profiles
                .map { src.baseDir + "/" + $0 + "/History" }
                .filter { fm.fileExists(atPath: $0) }
        }
    }

    private func importOne(bundleId: String, format: Format, dbPath: String) async throws -> Int {
        // Read a WAL-safe COPY (never the live file the browser is writing).
        let tmp = try copyWithWAL(dbPath)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let queue = try DatabaseQueue(path: tmp.path)   // writable copy → applies WAL on open

        let cursorKey = "zbseye.browserhist.cursor." + String(dbPath.hashValue)
        let cursor = Int64(UserDefaults.standard.string(forKey: cursorKey) ?? "") ?? 0

        let sql: String
        switch format {
        case .chromium:
            sql = """
                SELECT v.visit_time AS vt, u.url AS url, u.title AS title, u.visit_count AS vc
                FROM visits v JOIN urls u ON u.id = v.url
                WHERE v.visit_time > ? ORDER BY v.visit_time LIMIT 5000
                """
        case .safari:
            sql = """
                SELECT hv.visit_time AS vt, hi.url AS url, hv.title AS title, hi.visit_count AS vc
                FROM history_visits hv JOIN history_items hi ON hi.id = hv.history_item
                WHERE hv.visit_time > ? ORDER BY hv.visit_time LIMIT 5000
                """
        }

        struct Visit: Sendable { let nativeTs: Int64; let tsMs: Int64; let url: String; let title: String?; let vc: Int? }
        let visits: [Visit] = try await queue.read { dbc in
            try Row.fetchAll(dbc, sql: sql, arguments: [cursor]).compactMap { r in
                guard let url: String = r["url"], !url.isEmpty, url.hasPrefix("http") else { return nil }
                let native: Int64
                let tsMs: Int64
                switch format {
                case .chromium:
                    native = r["vt"]                                   // µs since 1601-01-01
                    tsMs = (native - 11_644_473_600_000_000) / 1000    // → epoch ms
                case .safari:
                    let secs: Double = r["vt"]                         // seconds since 2001-01-01
                    native = Int64(secs)
                    tsMs = Int64((secs + 978_307_200) * 1000)          // → epoch ms
                }
                guard tsMs > 0 else { return nil }
                return Visit(nativeTs: native, tsMs: tsMs, url: url, title: r["title"], vc: r["vc"])
            }
        }
        guard !visits.isEmpty else { return 0 }

        try await db.pool.write { dbc in
            for v in visits {
                try dbc.execute(sql: """
                    INSERT OR IGNORE INTO browser_visits (ts, url, host, title, browser, visitCount)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [v.tsMs, v.url, DayActivityRepository.hostFromURL(v.url),
                                     v.title, bundleId, v.vc])
            }
        }
        if let maxNative = visits.map(\.nativeTs).max() {
            UserDefaults.standard.set(String(maxNative), forKey: cursorKey)
        }
        return visits.count
    }

    /// Copy the history DB + its -wal/-shm sidecars into a throwaway temp dir, so we read a consistent
    /// snapshot without touching the live file the browser holds open.
    private func copyWithWAL(_ path: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("zbseye-bh-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("History")
        try fm.copyItem(atPath: path, toPath: dest.path)
        for ext in ["-wal", "-shm"] where fm.fileExists(atPath: path + ext) {
            try? fm.copyItem(atPath: path + ext, toPath: dest.path + ext)
        }
        return dest
    }
}
