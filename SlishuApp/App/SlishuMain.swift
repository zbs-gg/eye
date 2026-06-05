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
        } else {
            SlishuApp.main()
        }
    }
}
