import Foundation

/// Orders the user-requested repair without owning capture state itself.
/// The health controller remains the sole recovery authority; this helper only
/// guarantees that every affected Eye-owned leg has drained before replacement
/// work is admitted.
@MainActor
enum CaptureRepairOrchestrator {
    static func run(
        affected: Set<CaptureLeg>,
        drainScreen: @escaping @MainActor () async -> Bool,
        drainSystemAudio: @escaping @MainActor () async -> Bool,
        restartScreen: @escaping @MainActor () -> Void,
        requestRepair: @escaping @MainActor (CaptureLeg) -> Void
    ) async -> Bool {
        var screenDrained = true
        var systemAudioDrained = true

        if affected.contains(.screen), affected.contains(.systemAudio) {
            async let screen = drainScreen()
            async let systemAudio = drainSystemAudio()
            (screenDrained, systemAudioDrained) = await (screen, systemAudio)
        } else if affected.contains(.screen) {
            screenDrained = await drainScreen()
        } else if affected.contains(.systemAudio) {
            systemAudioDrained = await drainSystemAudio()
        }

        guard screenDrained, systemAudioDrained else { return false }
        if affected.contains(.screen) { restartScreen() }
        for leg in CaptureLeg.allCases where affected.contains(leg) {
            requestRepair(leg)
        }
        return true
    }
}
