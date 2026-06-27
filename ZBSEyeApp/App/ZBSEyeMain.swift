import Foundation

/// Entry point. By default — a SwiftUI app. With the `--mcp` flag — an MCP stdio server (to launch from
/// Claude Desktop / Cursor: `ZBS Eye.app/Contents/MacOS/ZBS Eye --mcp`), with no GUI.
@main
struct ZBSEyeMain {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            // MCP stdio: dispatchMain() keeps the process alive and lets the concurrency pool work
            // (DispatchSemaphore.wait would dead-block the main thread and Task would never run).
            Task.detached {
                await ZBSEyeMCPServer.runStdio()
                exit(0)
            }
            dispatchMain()
        } else if CommandLine.arguments.contains("--import-history") {
            // Headless import of prior history from ~/.screenpipe (same as the button in Settings; handy for
            // scripts/checks). Idempotent — can be interrupted and resumed.
            Task.detached {
                do {
                    let db = try ZBSEyeDatabase(path: ZBSEyeDatabase.defaultURL().path)
                    let importer = HistoryImporter(db: db)
                    print("Importing from \(HistoryImporter.defaultSourcePath)…")
                    let report = try await importer.run { f, a in
                        print("  frames: \(f), audio: \(a)")
                    }
                    print("Done: +\(report.frames) frames, +\(report.audio) audio.")
                    exit(0)
                } catch {
                    FileHandle.standardError.write("Import failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
            dispatchMain()
        } else if let i = CommandLine.arguments.firstIndex(of: "--relocate"),
                  i + 1 < CommandLine.arguments.count {
            // Headless relocation of storage to <path>/ZBS Eye (same migrator as in the UI; no relaunch).
            // The GUI must be closed (otherwise COUNT parity wavers from concurrent writes).
            let chosen = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
            Task.detached {
                do {
                    let storage = try StorageManager()
                    let db = try ZBSEyeDatabase(path: ZBSEyeDatabase.defaultURL().path, runMigrations: false)
                    let report = try await StorageRelocator().migrate(
                        sourcePool: db.pool,
                        sourceDBURL: try ZBSEyeDatabase.defaultURL(),
                        sourceMedia: storage.mediaDirectory,
                        chosen: chosen,
                        progress: { p, m in print("  \(Int(p * 100))% \(m)") })
                    StorageLocation.setRoot(report.newDataRoot)
                    print("Relocated to: \(report.newDataRoot.path)")
                    print("  DB \(report.dbBytes) bytes, media \(report.mediaFilesCopied) files")
                    exit(0)
                } catch {
                    FileHandle.standardError.write("Relocation failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
            dispatchMain()
        } else if CommandLine.arguments.contains("--backup-now") {
            // Headless backup to iCloud (same as the button/schedule; handy for checks).
            Task.detached {
                do {
                    let storage = try StorageManager()
                    let db = try ZBSEyeDatabase(path: ZBSEyeDatabase.defaultURL().path, runMigrations: false)
                    let mgr = BackupManager(db: db, storage: storage)
                    let keep = UserDefaults.standard.object(forKey: "zbseye.backup.keepN") as? Int ?? 7
                    let r = try await mgr.makeBackup(keepN: keep)
                    print("Backup: \(r.url.path)")
                    print("  \(r.compressedBytes) bytes (from \(r.sourceBytes)), \(r.frames) frames")
                    exit(0)
                } catch {
                    FileHandle.standardError.write("Backup failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
            dispatchMain()
        } else if let i = CommandLine.arguments.firstIndex(of: "--backup-verify"),
                  i + 1 < CommandLine.arguments.count {
            // Unpack the snapshot and verify it (integrity + COUNT).
            let path = CommandLine.arguments[i + 1]
            do {
                let (ok, frames) = try BackupManager.verify(URL(fileURLWithPath: path))
                print("integrity_check=\(ok ? "ok" : "FAIL"), frames=\(frames)")
                exit(ok ? 0 : 2)
            } catch {
                FileHandle.standardError.write("Verify failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        } else {
            ZBSEyeApp.main()
        }
    }
}
