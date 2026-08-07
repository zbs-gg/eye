import Foundation
import CryptoKit

enum CallSurfaceKind: String, Codable, Sendable {
    case native
    case browser
    case generic
}

enum CallStateMarker: String, Codable, Sendable {
    case microphoneActivity = "microphone_activity"
    case nativeCallControls = "native_call_controls"
    case accessibilityParticipantRoster = "accessibility_participant_roster"
    case trustedBrowserCallState = "trusted_browser_call_state"
}

enum CallSurfaceCatalog {
    static let nativeBundlePrefixes = [
        "us.zoom",
        "com.microsoft.teams",
        "com.apple.FaceTime",
        "com.hnc.Discord",
        "com.tinyspeck.slack",
        "com.cisco.webex",
        "com.webex",
        "com.skype",
        "ru.keepcoder.Telegram",
        "org.telegram",
    ]

    /// Browser roots qualified for OS-only call detection in 0.5.1.
    ///
    /// Helper bundles are intentionally absent. The CoreAudio adapter walks each helper PID to one
    /// of these owning application roots before it reports evidence.
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "company.thebrowser.dia",
        "com.microsoft.edgemac",
    ]

    /// CoreAudio reports the audio process' own bundle id. Chromium commonly exposes a helper
    /// bundle whose process is not parented by the visible browser app, so ancestry alone cannot
    /// recover the qualified AX root. Accept only helper namespaces beneath an exact supported
    /// browser id and map them back to that root; look-alike prefixes remain unsupported.
    static func canonicalBrowserBundleID(forAudioProcessBundleID value: String?) -> String? {
        guard let value else { return nil }
        if browserBundleIDs.contains(value) { return value }
        if value == "com.google.Chrome.helper"
            || value.hasPrefix("com.google.Chrome.helper.") {
            return "com.google.Chrome"
        }
        if value == "com.microsoft.edgemac.helper"
            || value.hasPrefix("com.microsoft.edgemac.helper.") {
            return "com.microsoft.edgemac"
        }
        if value == "company.thebrowser.browser.helper"
            || value.hasPrefix("company.thebrowser.browser.helper.")
            || value == "company.thebrowser.dia.helper"
            || value.hasPrefix("company.thebrowser.dia.helper.") {
            return "company.thebrowser.dia"
        }
        return nil
    }
}

struct TrustedCallOrigin: Equatable, Codable, Sendable {
    let scheme: String
    let host: String

    static func normalize(_ rawValue: String) -> TrustedCallOrigin? {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              components.port == nil || components.port == 443,
              isAllowed(host: host)
        else { return nil }

        return TrustedCallOrigin(scheme: "https", host: host)
    }

    private static func isAllowed(host: String) -> Bool {
        switch host {
        case "meet.google.com", "teams.microsoft.com", "teams.live.com":
            return true
        case "zoom.us":
            return true
        default:
            return host.hasSuffix(".zoom.us")
                && host.count > "zoom.us".count + 1
        }
    }
}

struct CallSurfaceEvidence: Equatable, Codable, Sendable {
    let kind: CallSurfaceKind
    let ownerBundleID: String
    let trustedOrigin: TrustedCallOrigin?
    let marker: CallStateMarker?
    let observedAt: TimeInterval
}

struct CallEvidenceSnapshot: Equatable, Codable, Sendable {
    var now: TimeInterval
    /// Monotonic collection time. Safety latches must never depend on the wall clock, which can
    /// jump backwards after NTP, sleep, or a manual time change.
    var monotonicNow: TimeInterval
    var microphoneOwnerBundleID: String?
    /// Localized app name or executable basename. This is optional enrichment; admission never
    /// depends on it and no executable path is collected.
    var microphoneOwnerDisplayName: String? = nil
    var surface: CallSurfaceEvidence?
    var microphoneAudioActive: Bool
    var systemAudioActive: Bool
    var calendarHint: Bool
    var isStale: Bool
    var fingerprint: String
    /// The detector still owns this fingerprint through a bounded audio-route gap. This is end
    /// evidence for an active call, but not true idle for a suppressed session.
    var isRetainedMissing: Bool = false

    var hasTwoSidedAudio: Bool {
        microphoneAudioActive && systemAudioActive
    }

    var isStronglyIdle: Bool {
        !isStale
            && !isRetainedMissing
            && microphoneOwnerBundleID == nil
            && surface?.marker == nil
            && !microphoneAudioActive
            && !systemAudioActive
    }
}

enum CallDetectorFingerprint {
    /// Session fingerprints are local suppression keys, not user-visible app/title/origin strings.
    static func make(bundleID: String, sessionMarker: String, originHost: String?) -> String {
        let material = [bundleID.lowercased(), originHost?.lowercased() ?? "-", sessionMarker]
            .joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Stable only for one concrete app process + call surface. Unlike the activation fingerprint,
    /// this deliberately survives an audio-route reconnect so a rejected call cannot immediately
    /// re-arm with a fresh UUID.
    static func makeSurfaceKey(
        bundleID: String,
        rootPID: Int32,
        surfaceDiscriminator: String,
        originHost: String?
    ) -> String {
        make(
            bundleID: bundleID,
            sessionMarker: "root:\(rootPID)|surface:\(surfaceDiscriminator)",
            originHost: originHost
        )
    }
}

/// One production seam from grouped CoreAudio evidence plus a bounded AX classification to the
/// policy snapshot. Keeping this composition pure lets the release matrix exercise the actual
/// helper-grouping/AX/policy chain instead of manufacturing already-qualified snapshots.
enum BrowserCallAdmission {
    static func evidence(
        group: CallAudioApplicationGroup,
        inspection: BrowserCallSurfaceInspection,
        observedAt: TimeInterval,
        monotonicNow: TimeInterval,
        fingerprint: String
    ) -> CallEvidenceSnapshot? {
        guard group.ownerKind == .browser,
              CallSurfaceCatalog.browserBundleIDs.contains(group.ownerBundleID),
              group.inputActive,
              group.outputActive,
              inspection.isTrustedCall,
              let origin = inspection.trustedOrigin
        else { return nil }

        return CallEvidenceSnapshot(
            now: observedAt,
            monotonicNow: monotonicNow,
            microphoneOwnerBundleID: group.ownerBundleID,
            surface: CallSurfaceEvidence(
                kind: .browser,
                ownerBundleID: group.ownerBundleID,
                trustedOrigin: origin,
                marker: .trustedBrowserCallState,
                observedAt: observedAt
            ),
            microphoneAudioActive: group.inputActive,
            systemAudioActive: group.outputActive,
            calendarHint: false,
            isStale: false,
            fingerprint: fingerprint
        )
    }
}

enum CallDetectionDecision: Equatable, Sendable {
    case none
    case start(fingerprint: String)
    case activity(fingerprint: String)
    case strongEnd(fingerprint: String)
    case becameIdle(fingerprint: String)
}

struct CallSurfaceTrustDecision: Equatable, Sendable {
    let surfaceConfirmed: Bool
    let unknownSince: TimeInterval?
}

/// Keeps one transient AX failure from splitting a call, but never lets a previously trusted
/// surface turn two-sided audio into permanent proof after Accessibility stops answering.
enum CallSurfaceTrustWindow {
    static func decide(
        previouslyConfirmed: Bool,
        latestSurfaceMatch: Bool?,
        trustReadFailed: Bool,
        unknownSince: TimeInterval?,
        now: TimeInterval,
        maximumUnknown: TimeInterval
    ) -> CallSurfaceTrustDecision {
        if let latestSurfaceMatch {
            return CallSurfaceTrustDecision(
                surfaceConfirmed: latestSurfaceMatch,
                unknownSince: nil
            )
        }

        let started = unknownSince ?? (trustReadFailed ? now : nil)
        guard let started else {
            // A background browser tab can disappear from the exposed AX tree even though the
            // retained control did not fail. That ambiguity alone is not a trust-read failure.
            return CallSurfaceTrustDecision(
                surfaceConfirmed: previouslyConfirmed,
                unknownSince: nil
            )
        }
        guard now - started < maximumUnknown else {
            return CallSurfaceTrustDecision(surfaceConfirmed: false, unknownSince: nil)
        }
        return CallSurfaceTrustDecision(
            surfaceConfirmed: previouslyConfirmed,
            unknownSince: started
        )
    }
}

/// Pure confidence policy for automatic call capture.
///
/// Adapters collect evidence; this reducer decides whether it is sufficient. It never touches audio
/// hardware, persistence, or UI, which keeps false-positive scenarios deterministic and testable.
struct CallDetectionPolicy: Sendable {
    private enum State: Sendable {
        case idle
        case active(fingerprint: String, kind: CallSurfaceKind)
        case suppressed(fingerprint: String)
    }

    private static let maximumStaleActivity: TimeInterval = 8

    private var state: State = .idle
    private var staleSince: TimeInterval?

    mutating func reduce(_ evidence: CallEvidenceSnapshot) -> CallDetectionDecision {
        switch state {
        case .idle:
            guard isEligibleToStart(evidence) else { return .none }
            let kind = evidence.surface?.kind ?? .generic
            staleSince = nil
            state = .active(fingerprint: evidence.fingerprint, kind: kind)
            return .start(fingerprint: evidence.fingerprint)

        case let .active(fingerprint, kind):
            // A failed HAL/AX collection is unknown, not end evidence. Preserve the current capture
            // through a transient read, but a persistently broken collector must not record forever.
            if evidence.isStale {
                let started = staleSince ?? evidence.monotonicNow
                staleSince = started
                guard evidence.monotonicNow - started <= Self.maximumStaleActivity else {
                    return .strongEnd(fingerprint: fingerprint)
                }
                return .activity(fingerprint: fingerprint)
            }
            staleSince = nil
            if evidence.isStronglyIdle || evidence.fingerprint != fingerprint {
                return .strongEnd(fingerprint: fingerprint)
            }
            guard isEligibleToContinue(evidence, fingerprint: fingerprint, kind: kind) else {
                return .strongEnd(fingerprint: fingerprint)
            }
            return .activity(fingerprint: fingerprint)

        case let .suppressed(fingerprint):
            if evidence.isStronglyIdle {
                state = .idle
                return .becameIdle(fingerprint: fingerprint)
            }
            if evidence.fingerprint != fingerprint, isEligibleToStart(evidence) {
                let kind = evidence.surface?.kind ?? .generic
                staleSince = nil
                state = .active(fingerprint: evidence.fingerprint, kind: kind)
                return .start(fingerprint: evidence.fingerprint)
            }
            return .none
        }
    }

    mutating func reject(fingerprint: String) {
        staleSince = nil
        state = .suppressed(fingerprint: fingerprint)
    }

    private func isEligibleToStart(_ evidence: CallEvidenceSnapshot) -> Bool {
        guard !evidence.isStale,
              !evidence.isRetainedMissing,
              let ownerBundleID = evidence.microphoneOwnerBundleID,
              CallAudioAutomaticOwnerRolePolicy.role(forBundleID: ownerBundleID) == .initiator,
              evidence.microphoneAudioActive
        else { return false }
        return true
    }

    private func isEligibleToContinue(
        _ evidence: CallEvidenceSnapshot,
        fingerprint: String,
        kind: CallSurfaceKind
    ) -> Bool {
        guard !evidence.isStale, evidence.fingerprint == fingerprint else { return false }
        _ = kind // Known native/browser classification is enrichment, never an admission gate.
        guard let ownerBundleID = evidence.microphoneOwnerBundleID,
              CallAudioAutomaticOwnerRolePolicy.role(forBundleID: ownerBundleID) == .initiator
        else { return false }
        // The universal boundary is microphone activity. Output playback and AX call controls may
        // enrich context, but cannot hold a Call open forever after input disappears. A mute/device
        // switch enters the existing 30-second grace and resumes the same fingerprint on return.
        return evidence.microphoneAudioActive
    }
}
