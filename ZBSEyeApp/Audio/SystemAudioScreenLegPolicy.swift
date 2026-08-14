import CoreMedia
import ScreenCaptureKit

/// ScreenCaptureKit keeps a video leg even when Eye consumes only system
/// audio. Keep that unavoidable leg valid but nearly idle: call audio still
/// arrives at its native cadence, while the compositor is not asked for a new
/// throwaway frame every second.
enum SystemAudioScreenLegPolicy {
    static let width = 2
    static let height = 2
    static let queueDepth = 1
    static let frameInterval = CMTime(value: 60, timescale: 1)

    static func apply(to configuration: SCStreamConfiguration) {
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = frameInterval
        configuration.queueDepth = queueDepth
        configuration.showsCursor = false
    }
}
