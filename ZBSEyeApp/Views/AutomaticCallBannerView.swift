import AppKit
import SwiftUI

/// One presentation of the automatic-call state for both the main workspace and the
/// permission-free floating panel. Actions are explicit so this view never owns lifecycle state.
struct AutomaticCallBannerView: View {
    let state: AutomaticCallBannerState
    let rejectionInProgress: Bool
    let onReject: () -> Void
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            switch state.phase {
            case .started, .endingGrace:
                Button("Not a call", role: .destructive, action: onReject)
                    .disabled(rejectionInProgress)
                    .help("Stop and permanently remove only this automatically detected call")
            case .endedUndo:
                Button("Undo", action: onUndo)
                    .buttonStyle(.borderedProminent)
                    .help("Resume the same call without losing its end boundary")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var title: LocalizedStringKey {
        switch state.phase {
        case .started: "Call recording started"
        case .endingGrace: "Call may have ended"
        case .endedUndo: "Call ended automatically"
        }
    }

    private var detail: LocalizedStringKey? {
        switch state.phase {
        case .started: "Eye found call controls and microphone use."
        case .endingGrace: "Waiting 30 seconds for the call to resume."
        case .endedUndo: "Undo is available for 15 seconds. Recording is not split."
        }
    }

    private var icon: String {
        switch state.phase {
        case .started: "phone.badge.waveform"
        case .endingGrace: "timer"
        case .endedUndo: "checkmark.circle"
        }
    }

    private var tint: Color {
        switch state.phase {
        case .started: .green
        case .endingGrace, .endedUndo: .orange
        }
    }
}

/// Mirrors `AutomaticCallBannerState` above other apps without notifications, activation, or a
/// second lifecycle. The panel is created only for the first non-nil state and then reused.
@MainActor
final class AutomaticCallPopupPresenter {
    typealias Action = @MainActor () -> Void

    private let onReject: Action
    private let onUndo: Action
    private var panel: AutomaticCallPopupPanel?
    private var hostingView: FirstMouseHostingView<AutomaticCallPopupContent>?

    init(
        onReject: @escaping Action,
        onUndo: @escaping Action
    ) {
        self.onReject = onReject
        self.onUndo = onUndo
    }

    func update(
        state: AutomaticCallBannerState?,
        rejectionInProgress: Bool
    ) {
        guard let state else {
            panel?.orderOut(nil)
            return
        }

        let content = AutomaticCallPopupContent(
            state: state,
            rejectionInProgress: rejectionInProgress,
            onReject: onReject,
            onUndo: onUndo
        )
        let panel = panel ?? makePanel(content: content)
        hostingView?.rootView = content
        position(panel)
        // Unlike makeKeyAndOrderFront, this does not activate Eye or open its main window.
        panel.orderFrontRegardless()
    }

    private func makePanel(content: AutomaticCallPopupContent) -> AutomaticCallPopupPanel {
        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 82)
        let panel = AutomaticCallPopupPanel(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        // Browsers and web-call surfaces can own floating utility windows of their own. Status-bar
        // level keeps this short, user-correctable privacy notice visible without activating Eye.
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .utilityWindow

        let hostingView = FirstMouseHostingView(rootView: content)
        hostingView.frame = contentRect
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.hostingView = hostingView
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let frame = panel.frame
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.maxY - frame.height - 18
            )
        )
    }
}

private struct AutomaticCallPopupContent: View {
    let state: AutomaticCallBannerState
    let rejectionInProgress: Bool
    let onReject: AutomaticCallPopupPresenter.Action
    let onUndo: AutomaticCallPopupPresenter.Action

    var body: some View {
        AutomaticCallBannerView(
            state: state,
            rejectionInProgress: rejectionInProgress,
            onReject: onReject,
            onUndo: onUndo
        )
        .frame(width: 500)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .padding(10)
    }
}

private final class AutomaticCallPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
