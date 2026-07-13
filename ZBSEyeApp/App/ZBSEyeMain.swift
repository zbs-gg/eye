import Foundation

/// Entry point. By default — a SwiftUI app. `--mcp` starts the read-only MCP
/// profile; `--mcp-full` explicitly adds screenshots and recording control.
@main
struct ZBSEyeMain {
    static func main() {
        if CommandLine.arguments.contains(AppRelaunchPlan.helperFlag) {
            guard let plan = AppRelaunchPlan(arguments: CommandLine.arguments) else {
                FileHandle.standardError.write(Data("Invalid relaunch helper arguments.\n".utf8))
                exit(2)
            }
            do {
                try plan.execute(
                    waitForExit: AppRelaunchPlan.waitForProcessExit,
                    openBundle: AppRelaunchPlan.openReplacement
                )
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Relaunch failed: \(error)\n".utf8))
                exit(1)
            }
        }
        LanguageManager.applyAtLaunch()   // apply the in-app language override before any UI loads
        let mcpProfile: MCPAccessProfile? = if CommandLine.arguments.contains("--mcp-full") {
            .advancedFull
        } else if CommandLine.arguments.contains("--mcp") {
            .memoryReadOnly
        } else {
            nil
        }
        if let mcpProfile {
            let dataRoot: URL
            do {
                dataRoot = try StorageLocation.requireExistingDataRoot()
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                if let expectedPath = ProcessInfo.processInfo.environment[
                    SystemMCPSelfTester.expectedRootEnvironmentKey
                ] {
                    let expected = URL(fileURLWithPath: expectedPath, isDirectory: true)
                        .standardizedFileURL
                        .resolvingSymlinksInPath()
                    guard expected == dataRoot else {
                        throw StorageLocationError.configuredRootUnavailable(expected.path)
                    }
                }
            } catch {
                FileHandle.standardError.write("MCP failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
            // MCP stdio: dispatchMain() keeps the process alive and lets the concurrency pool work
            // (DispatchSemaphore.wait would dead-block the main thread and Task would never run).
            Task.detached {
                await ZBSEyeMCPServer.runStdio(
                    profile: mcpProfile,
                    dataRoot: dataRoot
                )
                exit(0)
            }
            dispatchMain()
        } else if CommandLine.arguments.contains("--import-history") {
            // Headless import of prior history from ~/.screenpipe (same as the button in Settings; handy for
            // scripts/checks). Idempotent — can be interrupted and resumed.
            Task.detached {
                do {
                    _ = try StorageLocation.requireAvailableDataRoot()
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
            // The data-root process lock enforces that the GUI is closed, so
            // COUNT/media parity cannot race live writers.
            let chosen = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
            Task.detached {
                do {
                    let dataRoot = try StorageLocation.requireAvailableDataRoot()
                        .resolvingSymlinksInPath()
                        .standardizedFileURL
                    let relocationProcessLock = try StorageRelocationProcessLock(
                        dataRoot: dataRoot
                    )
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
                    withExtendedLifetime(relocationProcessLock) {}
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
                    _ = try StorageLocation.requireAvailableDataRoot()
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
