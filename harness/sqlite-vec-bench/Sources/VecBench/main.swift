import Foundation
import CSqliteVec

// SQLite-vec scale benchmark (ZBSEye blocking harness 1c).
// Проверяет: (1) статическую линковку sqlite-vec в Swift toolchain,
//            (2) реальную латентность KNN на 100k–1M × 384 (plain + filtered),
//            (3) размер БД на диске.

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// ── аргументы ──
var sizes = [100_000, 500_000, 1_000_000]
var queries = 100
var dim = 384
var k = 10

var argit = CommandLine.arguments.dropFirst().makeIterator()
while let a = argit.next() {
    switch a {
    case "--sizes": if let v = argit.next() { sizes = v.split(separator: ",").compactMap { Int($0) } }
    case "--queries": if let v = argit.next(), let n = Int(v) { queries = n }
    case "--dim": if let v = argit.next(), let n = Int(v) { dim = n }
    case "--k": if let v = argit.next(), let n = Int(v) { k = n }
    default: break
    }
}

func die(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }
func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ── быстрый LCG (детерминированный, без Foundation.random для скорости) ──
var rngState: UInt64 = 0x2545F4914F6CDD1D
@inline(__always) func nextUnit() -> Float {
    rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
    return Float(rngState >> 40) / Float(1 << 24)   // [0,1)
}
@inline(__always) func randomVector(into buf: inout [Float]) {
    var norm: Float = 0
    for i in 0..<buf.count { let v = nextUnit() * 2 - 1; buf[i] = v; norm += v * v }
    let inv = 1.0 / (norm.squareRoot() + 1e-9)
    for i in 0..<buf.count { buf[i] *= inv }     // L2-нормализация
}

// ── sqlite helpers ──
func exec(_ db: OpaquePointer, _ sql: String) {
    var err: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
        let m = err.map { String(cString: $0) } ?? "?"
        die("SQL error: \(m)\n  in: \(sql)")
    }
}

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    if sorted.isEmpty { return 0 }
    let idx = Int(Double(sorted.count - 1) * p)
    return sorted[idx]
}

// ── проверка статической линковки ──
eprint("=== ZBSEye sqlite-vec scale benchmark ===")
do {
    var probe: OpaquePointer?
    guard sqlite3_open(":memory:", &probe) == SQLITE_OK, let pdb = probe else { die("open :memory: failed") }
    var errmsg: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_vec_init(pdb, &errmsg, nil)        // статический init (SQLITE_CORE)
    if rc != SQLITE_OK { die("sqlite3_vec_init rc=\(rc): \(errmsg.map { String(cString: $0) } ?? "?")") }
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(pdb, "SELECT vec_version()", -1, &stmt, nil)
    if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
        eprint("✅ static link OK — sqlite-vec \(String(cString: c)), sqlite \(String(cString: sqlite3_libversion()))")
    } else { die("vec_version() failed — линковка не работает") }
    sqlite3_finalize(stmt); sqlite3_close(pdb)
}
eprint("dim=\(dim) k=\(k) queries=\(queries) sizes=\(sizes)\n")

struct Result: Codable {
    var n: Int, dim: Int
    var insertSec: Double, rowsPerSec: Double, dbBytes: Int64
    var pl50ms: Double, p95ms: Double
    var filterTs50ms: Double, filterTs95ms: Double
    var filterApp50ms: Double, filterApp95ms: Double
}
var results: [Result] = []

for n in sizes {
    let dbPath = NSTemporaryDirectory() + "zbseye-vecbench-\(n).sqlite"
    try? FileManager.default.removeItem(atPath: dbPath)

    var dbOpt: OpaquePointer?
    guard sqlite3_open(dbPath, &dbOpt) == SQLITE_OK, let db = dbOpt else { die("open \(dbPath) failed") }
    var verr: UnsafeMutablePointer<CChar>?
    if sqlite3_vec_init(db, &verr, nil) != SQLITE_OK { die("vec_init failed for \(n)") }

    exec(db, "PRAGMA journal_mode=WAL")
    exec(db, "PRAGMA synchronous=NORMAL")
    // vec0 с метадата-колонками для prefilter (ts, app_id)
    exec(db, "CREATE VIRTUAL TABLE vec_items USING vec0(app_id integer, ts integer, embedding float[\(dim)])")

    // ── вставка ──
    eprint("[\(n)] вставка \(n) × \(dim)…")
    var insStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT INTO vec_items(rowid, app_id, ts, embedding) VALUES (?,?,?,?)", -1, &insStmt, nil) == SQLITE_OK
    else { die("prepare insert failed: \(String(cString: sqlite3_errmsg(db)))") }

    var buf = [Float](repeating: 0, count: dim)
    let tIns = nowNs()
    exec(db, "BEGIN")
    for i in 0..<n {
        randomVector(into: &buf)
        sqlite3_reset(insStmt)
        sqlite3_bind_int64(insStmt, 1, Int64(i + 1))            // rowid
        sqlite3_bind_int64(insStmt, 2, Int64(i % 50))           // app_id (50 приложений)
        sqlite3_bind_int64(insStmt, 3, Int64(i))               // ts (монотонно)
        buf.withUnsafeBytes { raw in
            sqlite3_bind_blob(insStmt, 4, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        if sqlite3_step(insStmt) != SQLITE_DONE { die("insert step failed at \(i): \(String(cString: sqlite3_errmsg(db)))") }
        if i % 100_000 == 0 && i > 0 { exec(db, "COMMIT"); exec(db, "BEGIN"); eprint("    \(i)…") }
    }
    exec(db, "COMMIT")
    sqlite3_finalize(insStmt)
    let insertSec = Double(nowNs() - tIns) / 1e9
    exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")

    let dbBytes = (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0 ?? 0
    eprint(String(format: "    вставка %.1fс (%.0f rows/s), размер БД %.2f GB",
                  insertSec, Double(n) / insertSec, Double(dbBytes) / 1e9))

    // ── KNN бенч ──
    func benchQuery(label: String, sql: String, bindExtra: ((OpaquePointer) -> Void)?) -> (Double, Double) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            eprint("    [\(label)] prepare FAILED: \(String(cString: sqlite3_errmsg(db)))"); return (-1, -1)
        }
        var times: [Double] = []
        var qbuf = [Float](repeating: 0, count: dim)
        for _ in 0..<queries {
            randomVector(into: &qbuf)
            sqlite3_reset(stmt)
            qbuf.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int(stmt, 2, Int32(k))
            bindExtra?(stmt!)
            let t0 = nowNs()
            var rows = 0
            while sqlite3_step(stmt) == SQLITE_ROW { rows += 1 }
            times.append(Double(nowNs() - t0) / 1e6)   // ms
        }
        sqlite3_finalize(stmt)
        times.sort()
        return (percentile(times, 0.5), percentile(times, 0.95))
    }

    let cutoff = Int64(Double(n) * 0.9)   // последние 10% по ts ~ "недавнее окно"
    let (p50, p95) = benchQuery(label: "plain",
        sql: "SELECT rowid, distance FROM vec_items WHERE embedding MATCH ? AND k = ?", bindExtra: nil)
    let (f50, f95) = benchQuery(label: "ts-filter",
        sql: "SELECT rowid, distance FROM vec_items WHERE embedding MATCH ? AND k = ? AND ts > ?",
        bindExtra: { st in sqlite3_bind_int64(st, 3, cutoff) })
    let (a50, a95) = benchQuery(label: "app-filter",
        sql: "SELECT rowid, distance FROM vec_items WHERE embedding MATCH ? AND k = ? AND app_id = ?",
        bindExtra: { st in sqlite3_bind_int64(st, 3, 7) })

    eprint(String(format: "    KNN plain   p50=%.1fms p95=%.1fms", p50, p95))
    eprint(String(format: "    KNN ts>90%%  p50=%.1fms p95=%.1fms", f50, f95))
    eprint(String(format: "    KNN app=7   p50=%.1fms p95=%.1fms\n", a50, a95))

    results.append(Result(n: n, dim: dim, insertSec: insertSec, rowsPerSec: Double(n)/insertSec,
        dbBytes: dbBytes, pl50ms: p50, p95ms: p95, filterTs50ms: f50, filterTs95ms: f95,
        filterApp50ms: a50, filterApp95ms: a95))

    sqlite3_close(db)
    try? FileManager.default.removeItem(atPath: dbPath)
    try? FileManager.default.removeItem(atPath: dbPath + "-wal")
    try? FileManager.default.removeItem(atPath: dbPath + "-shm")
}

// ── JSON в stdout ──
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
struct Out: Codable { var dim: Int; var k: Int; var queries: Int; var results: [Result] }
if let data = try? enc.encode(Out(dim: dim, k: k, queries: queries, results: results)) {
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

eprint("=== вывод (порог Pro: ≤250k exact ок; 250k–1M только с prefilter; >1M — ANN/окно) ===")
for r in results {
    let verdict = r.p95ms <= 50 ? "✅ <50ms" : (r.p95ms <= 150 ? "⚠️ 50–150ms" : "❌ >150ms")
    eprint(String(format: "  %8d: plain p95=%.0fms %@  | ts-filter p95=%.0fms | %.2fGB",
                  r.n, r.p95ms, verdict as NSString, r.filterTs95ms, Double(r.dbBytes)/1e9))
}
