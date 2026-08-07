import AppKit
import SwiftUI

/// One presentation of the automatic-call state for both the main workspace and the
/// permission-free floating panel. Actions are explicit so this view never owns lifecycle state.
struct AutomaticCallBannerView: View {
    let state: AutomaticCallBannerState
    let rejectionInProgress: Bool
    let onEndAndSave: () -> Void
    let onReject: () -> Void
    let onNeverAutoRecord: (AutomaticCallExclusionTarget) -> Void
    @State private var pendingNeverAutoRecordTarget: AutomaticCallExclusionTarget?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                message
                Spacer(minLength: 8)
                horizontalActions
            }
            VStack(alignment: .leading, spacing: 10) {
                message
                ViewThatFits(in: .horizontal) {
                    horizontalActions
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    verticalActions
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.presentation.title)
        .confirmationDialog(
            Text(neverAutoRecordConfirmationTitle),
            isPresented: Binding(
                get: { pendingNeverAutoRecordTarget != nil },
                set: { isPresented in
                    if !isPresented { pendingNeverAutoRecordTarget = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let target = pendingNeverAutoRecordTarget {
                Button(
                    String(localized: "Never auto-record \(target.displayName)"),
                    role: .destructive
                ) {
                    pendingNeverAutoRecordTarget = nil
                    onNeverAutoRecord(target)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current Call will be saved. Future microphone use by this app won’t start a Call. Screen recording is unchanged.")
        }
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(state.presentation.title, systemImage: state.presentation.icon)
                .font(.callout.weight(.medium))
            Text(state.presentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }

    private var horizontalActions: some View {
        HStack(spacing: 8) {
            actionButtons
        }
    }

    private var verticalActions: some View {
        VStack(alignment: .trailing, spacing: 8) {
            actionButtons
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let target = state.neverAutoRecordTarget,
           let exclusionTitle = state.neverAutoRecordActionTitle {
            Button(exclusionTitle) {
                pendingNeverAutoRecordTarget = target
            }
            .disabled(rejectionInProgress)
            .lineLimit(2)
            .help("Save this Call and stop this app from starting automatic Calls")
        }
        if state.presentation.showsEndAndSave {
            Button("End & save", action: onEndAndSave)
                .buttonStyle(.borderedProminent)
                .disabled(rejectionInProgress)
                .help("Finish recording and save this call now")
        }
        if let rejectActionTitle = state.presentation.rejectActionTitle {
            Button(rejectActionTitle, role: .destructive, action: onReject)
                .disabled(rejectionInProgress)
                .help("Stop and permanently remove only this automatically detected call")
        }
        if state.phase == .finalizing || rejectionInProgress {
            ProgressView().controlSize(.small)
        }
    }

    private var neverAutoRecordConfirmationTitle: String {
        guard let target = pendingNeverAutoRecordTarget else {
            return String(localized: "Never auto-record this app?")
        }
        return String(localized: "Never auto-record \(target.displayName)?")
    }

    private var tint: Color {
        switch state.presentation.tone {
        case .positive: .green
        case .warning: .orange
        case .neutral: .secondary
        case .error: .red
        }
    }
}

/// Mirrors `AutomaticCallBannerState` above other apps without notifications, activation, or a
/// second lifecycle. The panel is created only for the first non-nil state and then reused.
@MainActor
final class AutomaticCallPopupPresenter {
    typealias Action = @MainActor () -> Void
    typealias ExclusionAction = @MainActor (AutomaticCallExclusionTarget) -> Void

    private let onEndAndSave: Action
    private let onReject: Action
    private let onNeverAutoRecord: ExclusionAction
    private var panel: AutomaticCallPopupPanel?
    private var hostingView: FirstMouseHostingView<AutomaticCallPopupContent>?

    init(
        onEndAndSave: @escaping Action,
        onReject: @escaping Action,
        onNeverAutoRecord: @escaping ExclusionAction
    ) {
        self.onEndAndSave = onEndAndSave
        self.onReject = onReject
        self.onNeverAutoRecord = onNeverAutoRecord
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
            onEndAndSave: onEndAndSave,
            onReject: onReject,
            onNeverAutoRecord: onNeverAutoRecord
        )
        let panel = panel ?? makePanel(content: content)
        hostingView?.rootView = content
        position(panel, state: state)
        // Unlike makeKeyAndOrderFront, this does not activate Eye or open its main window.
        panel.orderFrontRegardless()
    }

    private func makePanel(content: AutomaticCallPopupContent) -> AutomaticCallPopupPanel {
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: AutomaticCallPopupGeometry.targetWidth,
            height: AutomaticCallPopupGeometry.wideHeight
        )
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

    private func position(_ panel: NSPanel, state: AutomaticCallBannerState) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let geometry = AutomaticCallPopupGeometry.fit(
            visibleX: visibleFrame.minX,
            visibleY: visibleFrame.minY,
            visibleWidth: visibleFrame.width,
            visibleHeight: visibleFrame.height,
            actionCount: state.visibleActionCount
        )
        panel.setFrame(
            NSRect(
                x: geometry.x,
                y: geometry.y,
                width: geometry.width,
                height: geometry.height
            ),
            display: false
        )
    }
}

private struct AutomaticCallPopupContent: View {
    let state: AutomaticCallBannerState
    let rejectionInProgress: Bool
    let onEndAndSave: AutomaticCallPopupPresenter.Action
    let onReject: AutomaticCallPopupPresenter.Action
    let onNeverAutoRecord: AutomaticCallPopupPresenter.ExclusionAction

    var body: some View {
        AutomaticCallBannerView(
            state: state,
            rejectionInProgress: rejectionInProgress,
            onEndAndSave: onEndAndSave,
            onReject: onReject,
            onNeverAutoRecord: onNeverAutoRecord
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
