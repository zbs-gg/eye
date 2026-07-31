import AppKit
import SwiftUI

struct BrowserCaptureSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var copied = false

    private static let privacyURL = URL(
        string: "https://github.com/zbs-gg/eye/blob/main/docs/BROWSER_BRIDGE_PRIVACY.md"
    )!

    static let chromeWebStoreURL = URL(
        string: "https://chromewebstore.google.com/detail/zbs-eye-browser-bridge/dancgjefofjomhclpgmilholpnfadolf"
    )!

    var body: some View {
        Form {
            Section("Status") {
                SwiftUI.TimelineView(.periodic(from: .now, by: 2)) { context in
                    LabeledContent("Browser Bridge") {
                        Label(statusText(at: context.date), systemImage: statusSymbol(at: context.date))
                            .foregroundStyle(statusColor(at: context.date))
                    }
                }
                Text("Browser Capture is off by default. After you enable the extension, it reads only the active tab in the focused Chromium window—and only while ZBS Eye is recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Install") {
                Link(destination: Self.chromeWebStoreURL) {
                    Label("Open Chrome Web Store", systemImage: "arrow.up.right.square")
                }
                Button {
                    revealBundledExtension()
                } label: {
                    Label("Reveal bundled extension", systemImage: "folder")
                }
                Text("Fallback: open chrome://extensions, turn on Developer mode, choose Load unpacked, then select the revealed Extension folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connect") {
                LabeledContent("Write-only token") {
                    Text(verbatim: maskedToken)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button {
                    copyToken()
                } label: {
                    Label(copied ? "Copied" : "Copy token", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(env.server.browserToken == nil)
                Text("Paste this token into the extension. It can submit rendered page text to this Mac, but it cannot read Search, Timeline, screenshots, audio, or calls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Sent locally: visible rendered text, page title, and URL. Never sent: passwords, input or textarea values, selected form values, hidden elements, scripts, or styles.")
                    .font(.callout)
                Link(destination: Self.privacyURL) {
                    Label("Read Browser Bridge privacy details", systemImage: "hand.raised")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Browser Capture")
    }

    private var maskedToken: String {
        guard let token = env.server.browserToken, !token.isEmpty else { return "—" }
        return String(repeating: "•", count: min(token.count, 24))
    }

    private func statusText(at date: Date) -> String {
        guard env.recording.isCapturing else { return String(localized: "Paused") }
        switch env.server.browserConnectionStatus(now: date) {
        case .connected: return String(localized: "Connected")
        case .stale: return String(localized: "Waiting")
        case .disconnected: return String(localized: "Not connected")
        }
    }

    private func statusSymbol(at date: Date) -> String {
        guard env.recording.isCapturing else { return "pause.circle.fill" }
        switch env.server.browserConnectionStatus(now: date) {
        case .connected: return "checkmark.circle.fill"
        case .stale: return "clock.fill"
        case .disconnected: return "circle.dashed"
        }
    }

    private func statusColor(at date: Date) -> Color {
        guard env.recording.isCapturing else { return .secondary }
        switch env.server.browserConnectionStatus(now: date) {
        case .connected: return .green
        case .stale: return .orange
        case .disconnected: return .secondary
        }
    }

    private func copyToken() {
        guard let token = env.server.browserToken else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func revealBundledExtension() {
        guard let url = Bundle.main.url(forResource: "Extension", withExtension: nil) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
