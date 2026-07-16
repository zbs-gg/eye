import SwiftUI

struct CallCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandMenu("Call") {
            Button("Start Call") { env.calls.start() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(env.calls.isActive)
            Button("Bookmark Call") { env.calls.bookmark() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(env.calls.snapshot.phase != .recording)
            Button("End Call") { env.calls.end() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(env.calls.snapshot.phase != .recording)
        }
    }
}
