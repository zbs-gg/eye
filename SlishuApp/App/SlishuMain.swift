import Foundation

/// Entry-point. По умолчанию — SwiftUI-приложение. С флагом `--mcp` — MCP stdio-сервер (для запуска из
/// Claude Desktop / Cursor: `Slishu.app/Contents/MacOS/Slishu --mcp`), без GUI.
@main
struct SlishuMain {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            // MCP stdio: dispatchMain() держит процесс и даёт concurrency-пулу работать
            // (DispatchSemaphore.wait мёртво блокировал бы main-thread и Task не запускался бы).
            Task.detached {
                await SlishuMCPServer.runStdio()
                exit(0)
            }
            dispatchMain()
        } else if CommandLine.arguments.contains("--import-screenpipe") {
            // Headless-импорт из ~/.screenpipe (то же, что кнопка в Настройках; удобно для
            // скриптов/проверки). Идемпотентен — можно прерывать и продолжать.
            Task.detached {
                do {
                    let db = try SlishuDatabase(path: SlishuDatabase.defaultURL().path)
                    let importer = ScreenpipeImporter(db: db)
                    print("Импорт из \(ScreenpipeImporter.defaultSourcePath)…")
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
        } else {
            SlishuApp.main()
        }
    }
}
