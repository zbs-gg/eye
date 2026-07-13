import Darwin
import Foundation

do {
    let status = try ScreenUnderstandingDatasetCommand().run(
        arguments: Array(CommandLine.arguments.dropFirst()),
        writeStandardOutput: { try FileHandle.standardOutput.write(contentsOf: $0) }
    )
    Darwin.exit(status)
} catch let error as ScreenUnderstandingDatasetCommandError {
    let message = "error: \(error.localizedDescription)\n"
    try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    Darwin.exit(2)
} catch {
    try? FileHandle.standardError.write(
        contentsOf: Data("error: dataset preparation failed\n".utf8)
    )
    Darwin.exit(1)
}
