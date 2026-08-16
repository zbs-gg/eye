import CoreAudio
import AudioToolbox

/// Pure format validation and downmixing for Core Audio process-tap buffers.
/// Kept separate so the unhosted tests can exercise byte layout without
/// creating a real tap or changing macOS audio permissions.
enum SystemAudioTapPCM {
    static func supports(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format.mBitsPerChannel == 32
            && format.mSampleRate > 0
            && format.mChannelsPerFrame > 0
    }

    static func decode(
        inputData: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription
    ) -> (samples: [Float], rms: Float)? {
        guard supports(format) else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard !buffers.isEmpty else { return nil }

        var frameCount = Int.max
        var totalChannels = 0
        for buffer in buffers {
            let channels = max(1, Int(buffer.mNumberChannels))
            guard buffer.mData != nil else { continue }
            frameCount = min(
                frameCount,
                Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            )
            totalChannels += channels
        }
        guard frameCount > 0, frameCount != Int.max, totalChannels > 0 else {
            return nil
        }

        var mono = [Float](repeating: 0, count: frameCount)
        for buffer in buffers {
            let channels = max(1, Int(buffer.mNumberChannels))
            guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            for frame in 0..<frameCount {
                let base = frame * channels
                for channel in 0..<channels {
                    mono[frame] += samples[base + channel]
                }
            }
        }
        let divisor = Float(totalChannels)
        var squareSum: Float = 0
        for index in mono.indices {
            mono[index] /= divisor
            squareSum += mono[index] * mono[index]
        }
        return (mono, (squareSum / Float(frameCount)).squareRoot())
    }
}
