import CoreGraphics
import XCTest

final class ScreenUnderstandingVisionAdapterTests: XCTestCase {
    func testVisionAdapterReturnsOnlyLabelsAndConfidence() throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 64 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage())

        let result = try ScreenUnderstandingVisionAdapter().classify(image)
        XCTAssertFalse(result.labels.isEmpty)
        XCTAssertTrue(result.labels.allSatisfy { 0...1 ~= $0.confidence })
        XCTAssertNil(result.summary)
        XCTAssertTrue(result.atomicFacts.isEmpty)
    }
}
