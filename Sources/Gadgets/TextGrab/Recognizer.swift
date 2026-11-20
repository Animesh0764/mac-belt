import CoreGraphics
import Foundation
import TextGrabCore
import Vision

/// What OCR found in an image.
struct OCRResult: Equatable, Sendable {
    var lines: [RecognizedLine]
    /// QR code / barcode payloads.
    var codes: [String]
}

protocol TextRecognizer: Sendable {
    func recognize(_ image: CGImage, readCodes: Bool) async throws -> OCRResult
}

/// Apple's on-device text recognition (Vision). Nothing leaves your Mac.
struct VisionRecognizer: TextRecognizer {
    func recognize(_ image: CGImage, readCodes: Bool) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try Self.run(image, readCodes: readCodes))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func run(_ image: CGImage, readCodes: Bool) throws -> OCRResult {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        var requests: [VNRequest] = [text]
        let barcodes = VNDetectBarcodesRequest()
        if readCodes { requests.append(barcodes) }

        try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)

        let lines: [RecognizedLine] = (text.results ?? []).compactMap { obs in
            guard let s = obs.topCandidates(1).first?.string else { return nil }
            let b = obs.boundingBox  // normalised, origin bottom-left
            return RecognizedLine(s, x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }
        var codes: [String] = []
        if readCodes {
            for obs in barcodes.results ?? [] {
                if let p = obs.payloadStringValue, !p.isEmpty, !codes.contains(p) { codes.append(p) }
            }
        }
        // A QR code's payload sometimes also shows up as OCR "text" (e.g. printed under it); keep one.
        let filtered = lines.filter { !codes.contains($0.text) }
        return OCRResult(lines: filtered, codes: codes)
    }
}
