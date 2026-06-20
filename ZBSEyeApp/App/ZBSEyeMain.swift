import Foundation

/// Entry-point. По умолчанию — SwiftUI-приложение. С флагом `--mcp` — MCP stdio-сервер (для запуска из
/// Claude Desktop / Cursor: `ZBS Eye.app/Contents/MacOS/ZBS Eye --mcp`), без GUI.
@main
struct ZBSEyeMain {
    static func main() {
        // ПЕРВЫМ делом (до открытия БД и чтения настроек любым режимом): одноразовые миграции после
        // ребрендинга кодовой базы — ключи UserDefaults на новый префикс, перенос данных со старого
        // имени папки на «ZBS Eye», затем переименование файла базы на новое имя.
        StorageLocation.migrateLegacyDefaultsIfNeeded()
        StorageLocation.migrateFromLegacyNameIfNeeded()
        StorageLocation.migrateDatabaseFilenameIfNeeded()
        if CommandLine.arguments.contains("--mcp") {
            // MCP stdio: dispatchMain() держит процесс и даёт concurrency-пулу работать
            // (DispatchSemaphore.wait мёртво блокировал бы main-thread и Task не запускался бы).
            Task.detached {
                await ZBSEyeMCPServer.runStdio()
                exit(0)
            }
            dispatchMain()
        } else if CommandLine.arguments.contains("--import-history") {
            // Headless-импорт прежней истории из ~/.screenpipe (то же, что кнопка в Настройках; удобно для
            // скриптов/проверки). Идемпотентен — можно прерывать и продолжать.
            Task.detached {
                do {
                    let db = try ZBSEyeDatabase(path: ZBSEyeDatabase.defaultURL().path)
                    let importer = HistoryImporter(db: db)
                    print("Импорт из \(HistoryImporter.defaultSourcePath)…")
                    let report = try await importer.run { f, a in
                        print("  кадров: \(f), аудио: \(a)")
                    }
                    print("Готово: +\(report.frames) кадров, +\(report.audio) аудио.")
                    exit(0)
                } catch {
                    FileHandle.standardError.write("Импорт упал: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
            dispatchMain()
        } else if let i = CommandLine.arguments.firstIndex(of: "--relocate"),
                  i + 1 < CommandLine.arguments.count {
            // Headless-перенос хранилища в <path>/ZBS Eye (тот же мигратор, что в UI; без relaunch).
            // GUI должен быть закрыт (иначе COUNT-parity дрогнет от конкурентной записи).
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
                    print("Перенесено в: \(report.newDataRoot.path)")
                    print("  БД \(report.dbBytes) байт, медиа \(report.mediaFilesCopied) файлов")
                    exit(0)
                } catch {
                    FileHandle.standardError.write("Перенос упал: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
            dispatchMain()
        } else if CommandLine.arguments.contains("--backup-now") {
            // Headless-бэкап в iCloud (то же, что кнопка/расписание; удобно для проверки).
            Task.detached {
                do {
                    let storage = try StorageManager()
                    let db = try ZBSEyeDatabase(path: ZBSEyeDatabase.defaultURL().path, runMigrations: false)
                    let mgr = BackupManager(db: db, storage: storage)
                    let keep = UserDefaults.standard.object(forKey: "zbseye.backup.keepN") as? Int ?? 7
                    let r = try await mgr.makeBackup(keepN: keep)
                    print("Бэкап: \(r.url.path)")
                    print("  \(r.compressedBytes) байт (из \(r.sourceBytes)), \(r.frames) кадров")
                    exit(0)
                } catch {
                    FileHandle.standardError.write("Бэкап упал: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
            dispatchMain()
        } else if let i = CommandLine.arguments.firstIndex(of: "--backup-verify"),
                  i + 1 < CommandLine.arguments.count {
            // Распаковать снапшот и проверить (integrity + COUNT).
            let path = CommandLine.arguments[i + 1]
            do {
                let (ok, frames) = try BackupManager.verify(URL(fileURLWithPath: path))
                print("integrity_check=\(ok ? "ok" : "FAIL"), кадров=\(frames)")
                exit(ok ? 0 : 2)
            } catch {
                FileHandle.standardError.write("Verify упал: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        } else {
            ZBSEyeApp.main()
        }
    }
}
