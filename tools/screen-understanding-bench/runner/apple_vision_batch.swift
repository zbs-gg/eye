import CoreGraphics
import Foundation
import ImageIO
import Vision

private struct Job: Decodable {
    let caseID: String
    let imagePath: String
}

private struct Label: Encodable {
    let identifier: String
    let confidence: Double
}

private struct Output: Encodable {
    let caseID: String
    let labels: [Label]
    let errors: [String]
}

private let minimumConfidence = 0.01
private let maximumLabels = 5

private enum BatchFailure: Error {
    case invalidInvocation
    case unreadableJob
    case invalidJob
    case outputEncoding
}

private func decodeImage(path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private func classify(_ job: Job) -> Output {
    guard let image = decodeImage(path: job.imagePath) else {
        return Output(caseID: job.caseID, labels: [], errors: ["image-decode-failed"])
    }
    do {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let ranked = (request.results ?? []).compactMap { result -> Label? in
            guard result.confidence >= Float(minimumConfidence) else { return nil }
            return Label(
                identifier: result.identifier,
                confidence: Double(result.confidence)
            )
        }.sorted {
            if $0.confidence == $1.confidence {
                return $0.identifier < $1.identifier
            }
            return $0.confidence > $1.confidence
        }
        let labels = Array(ranked.prefix(maximumLabels))
        return Output(caseID: job.caseID, labels: labels, errors: [])
    } catch {
        return Output(caseID: job.caseID, labels: [], errors: ["classification-failed"])
    }
}

private func run() throws {
    guard CommandLine.arguments.count == 2 else { throw BatchFailure.invalidInvocation }
    let jobURL = URL(fileURLWithPath: CommandLine.arguments[1])
    guard let data = try? Data(contentsOf: jobURL),
          let text = String(data: data, encoding: .utf8) else {
        throw BatchFailure.unreadableJob
    }
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let lineData = String(line).data(using: .utf8),
              let job = try? decoder.decode(Job.self, from: lineData) else {
            throw BatchFailure.invalidJob
        }
        let output = autoreleasepool { classify(job) }
        guard let encoded = try? encoder.encode(output),
              let rendered = String(data: encoded, encoding: .utf8) else {
            throw BatchFailure.outputEncoding
        }
        print(rendered)
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("apple-vision-batch failed\n".utf8))
    exit(2)
}
