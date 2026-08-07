import AppKit
import Foundation
import Observation

/// How audio capture is gated. Screen capture is unaffected by this — only audio.
///  - off:          never capture audio, even while recording.
///  - meetingsOnly: capture while a Call is active. Any non-excluded app using the microphone can
///                  start one. The raw value is retained for compatibility; the user-facing name is
///                  "Mic in use". The capture engine is fully STOPPED otherwise.
///  - always:       legacy continuous behavior (capture audio the whole time recording is on).
enum AudioMode: String, CaseIterable, Codable, Sendable {
    case off, meetingsOnly, always

    var label: String {
        switch self {
        case .off: return String(localized: "Off")
        case .meetingsOnly: return String(localized: "Mic in use")
        case .always: return String(localized: "Always")
        }
    }
}

/// A stable app identity returned by the picker. The bundle identifier, not the filename, is what
/// persists and participates in automatic-call admission.
struct AutoCallExcludedApplication: Equatable, Sendable {
    let bundleID: String
    let displayName: String
}

enum CallAudioSourcePolicy {
    static func requestedSources(
        audioMode: AudioMode,
        manualOverride: Bool?
    ) -> CallSourceSelection {
        audioMode == .off || manualOverride == false
            ? .none
            : CallSourceSelection(me: true, system: true)
    }

    static func allowsAutomaticCallStart(
        audioMode: AudioMode,
        manualOverride: Bool?,
        microphoneAvailable: Bool,
        systemAudioAvailable: Bool
    ) -> Bool {
        audioMode != .off
            && manualOverride != false
            && (microphoneAvailable || systemAudioAvailable)
    }

    static func mustEndActiveCall(
        audioMode: AudioMode,
        manualOverride: Bool?,
        callIsActive: Bool
    ) -> Bool {
        callIsActive && (audioMode == .off || manualOverride == false)
    }
}

/// Audio/transcription settings. Audio capture is a tri-state `audioMode` (default `.meetingsOnly`,
/// shown as "Mic in use"): the engine runs for automatically detected or explicit Calls, saving disk.
/// Persisted in UserDefaults; actual capture remains gated by microphone/screen permissions.
@MainActor
@Observable
final class AudioSettingsStore {
    /// The capture mode (persisted). Source of truth for whether audio should be recorded.
    var audioMode: AudioMode {
        didSet {
            guard audioMode != oldValue else { return }
            defaults.set(audioMode.rawValue, forKey: Self.modeKey)
            // an explicit mode change wins over a stale session override — otherwise "force on" + switch
            // to Off would keep recording while the UI says Off (a privacy trap). Off = hard stop.
            manualAudioOverride = nil
            onCaptureConfigurationChanged?()
        }
    }

    /// A separate toggle for background Timeline system audio. Confirmed/explicit calls request their
    /// own attributable mic + system legs regardless, while `.off` remains a hard stop for all audio.
    /// Ordinary playback alone never starts a Call; only microphone activity does.
    var recordSystemAudio: Bool {
        didSet {
            guard recordSystemAudio != oldValue else { return }
            defaults.set(recordSystemAudio, forKey: Self.sysKey)
            onCaptureConfigurationChanged?()
        }
    }

    /// Runtime-only: a meeting/call is currently detected (fed by MeetingDetector). NOT persisted.
    var meetingActive: Bool = false

    /// Session-only manual override of audio capture. nil = auto (follow mode/detector), true = force ON,
    /// false = force OFF. Wins over `audioMode` entirely. Cleared at a real recording-session stop
    /// (NOT on every syncAudio, or a re-sync would wipe it). NOT persisted.
    var manualAudioOverride: Bool? = nil

    /// One-time nudge (post-migration): audio now defaults to mic-triggered Calls. Persisted so we
    /// show it once; the storage key is intentionally unchanged.
    var migrationNudgeSeen: Bool {
        didSet {
            if migrationNudgeSeen != oldValue {
                defaults.set(migrationNudgeSeen, forKey: Self.nudgeKey)
            }
        }
    }

    /// Transcription health (refreshed when Settings opens) — to show "no on-device model".
    var health: TranscriptionHealth?
    var micEngineFailed = false

    /// Apps that may still appear in screen history but must not automatically create a Call when
    /// they use the microphone. Order is insertion-stable for a calm Settings UI.
    private(set) var autoCallExcludedBundleIDs: [String] {
        didSet {
            guard autoCallExcludedBundleIDs != oldValue else { return }
            defaults.set(autoCallExcludedBundleIDs, forKey: Self.autoCallExcludedAppsKey)
            onAutoCallExclusionsChanged?(Set(autoCallExcludedBundleIDs))
        }
    }

    /// Names are UI-only and resolved from installed applications on each launch. The bundle ID is
    /// the persisted identity and remains the fallback when an app is no longer installed.
    private(set) var autoCallExcludedDisplayNames: [String: String]

    /// Installed once by AppEnvironment. Views only edit intent; capture
    /// synchronization has one owner and therefore fires exactly once.
    @ObservationIgnored var onCaptureConfigurationChanged: (@MainActor () -> Void)?

    /// Installed by AppEnvironment so a changed exclusion list is applied to the live detector
    /// immediately instead of waiting for the polling fallback.
    @ObservationIgnored var onAutoCallExclusionsChanged: (@MainActor (Set<String>) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let applicationNameLookup: @MainActor (String) -> String?
    @ObservationIgnored private let applicationPicker: @MainActor () -> AutoCallExcludedApplication?

    @ObservationIgnored private static let modeKey = "zbseye.audio.audioMode"
    @ObservationIgnored private static let legacyKey = "zbseye.audio.transcriptionEnabled"
    @ObservationIgnored private static let sysKey = "zbseye.audio.recordSystemAudio"
    @ObservationIgnored private static let nudgeKey = "zbseye.audio.migrationNudgeSeen"
    @ObservationIgnored private static let autoCallExcludedAppsKey = "zbseye.audio.autoCallExcludedApps"

    /// The single decision point: should audio be captured right now? Manual override wins; otherwise mode.
    func audioShouldCapture() -> Bool {
        if audioMode == .off { return false }
        if let ov = manualAudioOverride { return ov }
        switch audioMode {
        case .off: return false
        case .always: return true
        case .meetingsOnly: return meetingActive
        }
    }

    /// Menu-bar quick control — cycles the session override: auto → force-on → force-off → auto.
    func cycleManualOverride() {
        switch manualAudioOverride {
        case nil: manualAudioOverride = true
        case .some(true): manualAudioOverride = false
        case .some(false): manualAudioOverride = nil
        }
    }

    /// Clear the session override (called at a real recording-session stop). Idempotent.
    func clearManualOverride() { manualAudioOverride = nil }

    /// Exact match only: excluding `com.example.App` must not also exclude its helper or another app
    /// with the same prefix. IDs are trimmed at the API boundary because surrounding whitespace can
    /// only be input damage, not part of a valid bundle identifier.
    func isAutoCallExcluded(_ bundleID: String) -> Bool {
        guard let canonical = Self.canonicalBundleID(bundleID) else { return false }
        return autoCallExcludedBundleIDs.contains(canonical)
    }

    @discardableResult
    func addAutoCallExcludedApp(bundleID: String, displayName: String? = nil) -> Bool {
        guard let canonical = Self.canonicalBundleID(bundleID) else { return false }
        guard !autoCallExcludedBundleIDs.contains(canonical) else { return false }
        if let displayName = Self.nonEmpty(displayName) {
            autoCallExcludedDisplayNames[canonical] = displayName
        } else if autoCallExcludedDisplayNames[canonical] == nil {
            autoCallExcludedDisplayNames[canonical] = applicationNameLookup(canonical) ?? canonical
        }
        autoCallExcludedBundleIDs.append(canonical)
        return true
    }

    @discardableResult
    func removeAutoCallExcludedApp(_ bundleID: String) -> Bool {
        guard let canonical = Self.canonicalBundleID(bundleID),
              autoCallExcludedBundleIDs.contains(canonical) else { return false }
        autoCallExcludedDisplayNames.removeValue(forKey: canonical)
        autoCallExcludedBundleIDs.removeAll { $0 == canonical }
        return true
    }

    /// Pick a `.app` and add its canonical bundle identifier. The picker is injected so the store's
    /// persistence/callback behavior can be verified without opening AppKit UI in unit tests.
    @discardableResult
    func addAutoCallExcludedAppViaPanel() -> Bool {
        guard let app = applicationPicker() else { return false }
        return addAutoCallExcludedApp(bundleID: app.bundleID, displayName: app.displayName)
    }

    init(
        defaults d: UserDefaults = .standard,
        applicationNameLookup: @escaping @MainActor (String) -> String? = AudioSettingsStore.lookupName,
        applicationPicker: @escaping @MainActor () -> AutoCallExcludedApplication? = AudioSettingsStore.pickApplication
    ) {
        defaults = d
        self.applicationNameLookup = applicationNameLookup
        self.applicationPicker = applicationPicker
        recordSystemAudio = (d.object(forKey: Self.sysKey) == nil) ? true : d.bool(forKey: Self.sysKey)
        migrationNudgeSeen = d.bool(forKey: Self.nudgeKey)

        let persistedExclusions = d.stringArray(forKey: Self.autoCallExcludedAppsKey) ?? []
        let canonicalExclusions = Self.canonicalBundleIDs(persistedExclusions)
        autoCallExcludedBundleIDs = canonicalExclusions
        autoCallExcludedDisplayNames = Dictionary(
            uniqueKeysWithValues: canonicalExclusions.map { bundleID in
                (bundleID, applicationNameLookup(bundleID) ?? bundleID)
            }
        )
        if canonicalExclusions != persistedExclusions {
            d.set(canonicalExclusions, forKey: Self.autoCallExcludedAppsKey)
        }

        // Migration → tri-state. The compatible `.meetingsOnly` raw value now means user-facing
        // "Mic in use". Only an explicit prior "audio off" is preserved as `.off`, so Eye never
        // starts recording audio someone deliberately disabled.
        if let raw = d.string(forKey: Self.modeKey), let mode = AudioMode(rawValue: raw) {
            audioMode = mode
        } else if d.object(forKey: Self.legacyKey) != nil && d.bool(forKey: Self.legacyKey) == false {
            audioMode = .off
            migrationNudgeSeen = true            // they had audio off; nothing to nudge about
            d.set(AudioMode.off.rawValue, forKey: Self.modeKey)
        } else {
            audioMode = .meetingsOnly
            d.set(AudioMode.meetingsOnly.rawValue, forKey: Self.modeKey)
        }
    }

    private static func canonicalBundleIDs(_ bundleIDs: [String]) -> [String] {
        var seen: Set<String> = []
        return bundleIDs.compactMap { raw in
            guard let canonical = canonicalBundleID(raw), seen.insert(canonical).inserted else {
                return nil
            }
            return canonical
        }
    }

    private static func canonicalBundleID(_ raw: String) -> String? {
        nonEmpty(raw)
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func lookupName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let bundle = Bundle(url: url)
        return (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private static func pickApplication() -> AutoCallExcludedApplication? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Don’t auto-record")
        panel.message = String(
            localized: "This app can still appear in screen history, but it won't automatically start a Call."
        )
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return nil }
        let displayName = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AutoCallExcludedApplication(bundleID: bundleID, displayName: displayName)
    }
}
