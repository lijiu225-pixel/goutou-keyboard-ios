import CoreGraphics
import Foundation
import CoreVideo
import ImageIO
import Vision

/// Low-cost scene evidence only; never groups messages or appends to a timeline.
enum ChatSceneProbe {
    static func recognize(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                          languages: [String]) throws -> ChatSceneEvidence {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        let supported = try text.supportedRecognitionLanguages()
        text.recognitionLanguages = languages.filter { supported.contains($0) }
        // Fast recognition may not support Chinese on every SDK. Read only the title
        // strip accurately; the full message region remains gated.
        let title = VNRecognizeTextRequest()
        title.recognitionLevel = .accurate
        title.usesLanguageCorrection = false
        title.recognitionLanguages = languages
        title.regionOfInterest = CGRect(x: 0.2, y: 0.84, width: 0.6, height: 0.16)
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 16
        rectangles.minimumAspectRatio = 0.08
        rectangles.maximumAspectRatio = 1
        rectangles.minimumSize = 0.025
        rectangles.minimumConfidence = 0.5
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try handler.perform([text, title, rectangles])
        let bodyResults = (text.results ?? []).filter { $0.boundingBox.midY < 0.84 }
        let observations = (bodyResults + (title.results ?? [])).compactMap { item -> LiveOCRObservation? in
            guard let line = item.topCandidates(1).first else { return nil }
            return .fromVision(text: line.string, confidence: Double(line.confidence), boundingBox: item.boundingBox)
        }
        let boxes = (rectangles.results ?? []).map {
            CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY,
                   width: $0.boundingBox.width, height: $0.boundingBox.height)
        }
        return ChatSceneDetector.probeEvidence(observations: observations, rectangles: boxes)
    }
}
