import Foundation

/// Final sink boundary for model-controlled text written to Markdown files.
/// The implementation is intentionally small so every provider (local,
/// subprocess, or remote) crosses the same policy before Obsidian can render it.
enum AutomationMarkdownSafety {
    static func modelOutput(_ text: String) -> String {
        escaped(text)
    }

    static func inlineMetadata(_ text: String) -> String {
        let oneLine = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return escaped(oneLine)
    }

    private static func escaped(_ text: String) -> String {
        // Escape ampersands first so the entities introduced below remain
        // stable. Raw HTML is rendered as text, and every Markdown image form
        // begins with `![`, so neither path can make Obsidian fetch a URL.
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "![", with: "\\![")
    }
}
