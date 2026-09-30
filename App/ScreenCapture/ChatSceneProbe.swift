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
        // Fast recognition may not support Chinese on every SDK. Read the navigation strip
        // accurately; the full message region remains gated.
        let title = VNRecognizeTextRequest()
        title.recognitionLevel = .accurate
        title.usesLanguageCorrection = false
        title.recognitionLanguages = languages
        // 微信导航栏可能是「返回 + 头像 + 名字 + 在线状态」，名字也可能偏左，
        // 所以这一带放宽到几乎整幅宽度（Vision 的 ROI 原点在左下）。
        title.regionOfInterest = CGRect(x: 0.06, y: 0.82, width: 0.90, height: 0.18)
        let rectangles = VNDetectRectanglesRequest()
        // 输入框是「宽而扁」的胶囊，气泡也是扁矩形。宽高比的量纲在不同 SDK 上口径不一致，
        // 这里两边都放开，精度交给门控自己的几何过滤（宽度 / 高度 / 位置）。
        rectangles.maximumObservations = 24
        rectangles.minimumAspectRatio = 0.02
        rectangles.maximumAspectRatio = 30
        rectangles.minimumSize = 0.02
        rectangles.minimumConfidence = 0.3
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try handler.perform([text, title, rectangles])
        let bodyResults = (text.results ?? []).filter { $0.boundingBox.midY < 0.82 }
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
