import Foundation
import CryptoKit

enum CallSurfaceKind: String, Codable, Sendable {
    case native
    case browser
}

enum CallStateMarker: String, Codable, Sendable {
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
}

struct TrustedCallOrigin: Equatable, Codable, Sendable {
    let scheme: String
    let host: String

    private static let allowedHosts: Set<String> = [
        "meet.google.com",
        "app.zoom.us",
        "zoom.us",
        "teams.microsoft.com",
    ]

    static func normalize(_ rawValue: String) -> TrustedCallOrigin? {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              allowedHosts.contains(host)
        else { return nil }

        return TrustedCallOrigin(scheme: "https", host: host)
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
    var microphoneOwnerBundleID: String?
    var surface: CallSurfaceEvidence?
    var microphoneAudioActive: Bool
    var systemAudioActive: Bool
    var calendarHint: Bool
    var isStale: Bool
    var fingerprint: String

    var hasTwoSidedAudio: Bool {
        microphoneAudioActive && systemAudioActive
    }

    var isStronglyIdle: Bool {
        microphoneOwnerBundleID == nil
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
}

enum CallDetectionDecision: Equatable, Sendable {
    case none
    case start(fingerprint: String)
    case activity(fingerprint: String)
    case strongEnd(fingerprint: String)
    case becameIdle
}

/// Pure confidence policy for automatic call capture.
///
/// Adapters collect evidence; this reducer decides whether it is sufficient. It never touches audio
/// hardware, persistence, or UI, which keeps false-positive scenarios deterministic and testable.
struct CallDetectionPolicy: Sendable {
    private enum State: Sendable {
        case idle
        case active(fingerprint: String)
        case suppressed(fingerprint: String)
    }

    private static let supportedBrowserPrefixes = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.kagi.kagimacOS",
    ]

    private static let maximumSurfaceAge: TimeInterval = 8

    private var state: State = .idle

    mutating func reduce(_ evidence: CallEvidenceSnapshot) -> CallDetectionDecision {
        switch state {
        case .idle:
            guard isEligibleToStart(evidence) else { return .none }
            state = .active(fingerprint: evidence.fingerprint)
            return .start(fingerprint: evidence.fingerprint)

        case let .active(fingerprint):
            if evidence.isStronglyIdle || evidence.fingerprint != fingerprint {
                return .strongEnd(fingerprint: fingerprint)
            }
            guard isEligibleToContinue(evidence, fingerprint: fingerprint) else {
                return .strongEnd(fingerprint: fingerprint)
            }
            return .activity(fingerprint: fingerprint)

        case let .suppressed(fingerprint):
            if evidence.isStronglyIdle {
                state = .idle
                return .becameIdle
            }
            if evidence.fingerprint != fingerprint, isEligibleToStart(evidence) {
                state = .active(fingerprint: evidence.fingerprint)
                return .start(fingerprint: evidence.fingerprint)
            }
            return .none
        }
    }

    mutating func reject(fingerprint: String) {
        state = .suppressed(fingerprint: fingerprint)
    }

    mutating func resetAfterCompletion() {
        state = .idle
    }

    private func isEligibleToStart(_ evidence: CallEvidenceSnapshot) -> Bool {
        guard !evidence.isStale,
              let micOwner = evidence.microphoneOwnerBundleID,
              let surface = evidence.surface,
              surface.ownerBundleID == micOwner,
              surface.marker != nil,
              evidence.now >= surface.observedAt,
              evidence.now - surface.observedAt <= Self.maximumSurfaceAge
        else { return false }

        switch surface.kind {
        case .native:
            return CallSurfaceCatalog.nativeBundlePrefixes.contains { micOwner.hasPrefix($0) }

        case .browser:
            return Self.supportedBrowserPrefixes.contains { micOwner.hasPrefix($0) }
                && surface.trustedOrigin != nil
                && surface.marker == .trustedBrowserCallState
                && evidence.hasTwoSidedAudio
        }
    }

    private func isEligibleToContinue(
        _ evidence: CallEvidenceSnapshot,
        fingerprint: String
    ) -> Bool {
        guard !evidence.isStale, evidence.fingerprint == fingerprint else { return false }
        return evidence.microphoneOwnerBundleID != nil
            || evidence.surface?.marker != nil
            || evidence.microphoneAudioActive
            || evidence.systemAudioActive
    }
}
