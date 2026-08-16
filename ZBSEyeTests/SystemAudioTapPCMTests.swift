import AudioToolbox
import XCTest

final class SystemAudioTapPCMTests: XCTestCase {
    func testInterleavedStereoDownmixesToMono() {
        var samples: [Float] = [1, -1, 0.5, 0.5, -0.25, 0.75]
        let decoded = samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            return withUnsafePointer(to: &list) {
                SystemAudioTapPCM.decode(inputData: $0, format: Self.floatFormat(channels: 2))
            }
        }

        XCTAssertEqual(decoded?.samples ?? [], [0, 0.5, 0.25])
        XCTAssertEqual(decoded?.rms ?? -1, 0.3227486, accuracy: 0.000_001)
    }

    func testRejectsNonFloatPCM() {
        var format = Self.floatFormat(channels: 2)
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger
        XCTAssertFalse(SystemAudioTapPCM.supports(format))
    }

    private static func floatFormat(channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
