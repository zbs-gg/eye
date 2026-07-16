import Foundation

struct CallAudioWindow: Sendable, Equatable {
    let callID: Int64
    let source: CallAudioSource
    let sampleRate: Int
    let startSample: Int64
    let endSample: Int64
    let pcm16LE: Data
}

struct CallAudioWindowAssembler: Sendable {
    private let secureRoot: SecureCallSpoolRoot

    init(root: URL) throws {
        secureRoot = try SecureCallSpoolRoot(root: root)
    }

    func assemble(
        snapshot: CallSpoolSnapshot,
        through watermark: CallSpoolWatermark
    ) throws -> CallAudioWindow {
        let ordered = snapshot.chunks.sorted {
            ($0.epoch, $0.sequence) < ($1.epoch, $1.sequence)
        }
        let startSample = ordered.first?.startSample ?? watermark.endSample
        var output = Data()
        for chunk in ordered where chunk.startSample < watermark.endSample {
            let endSample = min(chunk.endSample, watermark.endSample)
            let sampleCount = max(0, endSample - chunk.startSample)
            let byteCount = min(chunk.committedBytes, sampleCount * 2)
            guard byteCount > 0 else { continue }
            let data = try secureRoot.readPrefix(
                relativePath: chunk.relativePath,
                byteCount: Int(byteCount)
            )
            guard data.count == Int(byteCount), data.count.isMultiple(of: 2) else {
                throw CallSpoolError.shortRead
            }
            output.append(data)
        }
        return CallAudioWindow(
            callID: snapshot.callID,
            source: snapshot.source,
            sampleRate: snapshot.sampleRate,
            startSample: startSample,
            endSample: watermark.endSample,
            pcm16LE: output
        )
    }
}
