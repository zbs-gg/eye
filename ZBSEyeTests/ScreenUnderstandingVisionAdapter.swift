import CoreGraphics
import Foundation
import Vision

struct ScreenUnderstandingVisionLabel: Sendable, Equatable {
    var identifier: String
    var confidence: Double
}

struct ScreenUnderstandingVisionResult: Sendable, Equatable {
    var labels: [ScreenUnderstandingVisionLabel]
    var summary: String?
    var atomicFacts: [String]
}

struct ScreenUnderstandingVisionAdapter: Sendable {
    func classify(_ image: CGImage) throws -> ScreenUnderstandingVisionResult {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let labels = (request.results ?? []).map {
            ScreenUnderstandingVisionLabel(
                identifier: $0.identifier,
                confidence: Double($0.confidence)
            )
        }
        return ScreenUnderstandingVisionResult(
            labels: labels,
            summary: nil,
            atomicFacts: []
        )
    }
}
