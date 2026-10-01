import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Vision

/// 阶段 12A：把一帧屏幕画面在本机 OCR 成文字。
///
/// 设置与截图 OCR 保持一致（`.accurate` + 语言纠正 + 简体中文/英文），
/// 复用截图链路的气泡扫描，附加轻量角色证据；不改变截图识别或 Vision 识字参数。
/// 不生成图片文件、不落盘、不上传。
enum LiveScreenOCRProcessor {
    private static let pixelContext = CIContext(options: [.cacheIntermediates: false])

    /// 一行识别结果：文字 + Vision 给的归一化位置（原点在左下角，y 越大越靠上）。
    struct Line: Equatable {
        let text: String
        let box: CGRect
    }

    /// 按视觉阅读顺序排：先上后下，同一行从左到右。
    ///
    /// 纯计算，不依赖 Vision —— 所以可以在 CI 上直接验阅读顺序。
    static func readingOrder(_ lines: [Line], rowTolerance: CGFloat = 0.012) -> [String] {
        let usable = lines.filter { !$0.text.trimmed.isEmpty }
        let sorted = usable.sorted { lhs, rhs in
            let lhsRow = (lhs.box.midY / rowTolerance).rounded()
            let rhsRow = (rhs.box.midY / rowTolerance).rounded()
            if lhsRow != rhsRow { return lhsRow > rhsRow }
            return lhs.box.minX < rhs.box.minX
        }
        return sorted.map { $0.text.trimmed }
    }

    /// 真正跑 Vision：直接吃 `CVPixelBuffer`，方向来自帧元数据（拿不到就按正立处理）。
    static func recognize(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        languages: [String] = LiveScreenCaptureTuning.recognitionLanguages,
        now: Date = Date()
    ) throws -> LiveOCRSnapshot {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try handler.perform([request])

        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Line(text: candidate.string, box: observation.boundingBox)
        }
        // 阶段 12B：把几何一起带走（Vision 是左下角原点，这里换算成左上角原点）。
        let observations = (request.results ?? []).compactMap { observation -> LiveOCRObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return LiveOCRObservation.fromVision(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                boundingBox: observation.boundingBox
            )
        }
        let enriched = attachBubbleEvidence(to: observations, pixelBuffer: pixelBuffer, orientation: orientation)
        return LiveOCRSnapshot(timestamp: now, strings: readingOrder(lines), observations: enriched)
    }

    /// Only a small, oriented analysis image exists temporarily. The original frame is not copied or retained.
    static func attachBubbleEvidence(to observations: [LiveOCRObservation], pixelBuffer: CVPixelBuffer,
                                     orientation: CGImagePropertyOrientation) -> [LiveOCRObservation] {
        guard !observations.isEmpty, observations.count <= 200 else { return observations }
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        guard image.extent.width > 0, image.extent.height > 0 else { return observations }
        let scale = min(1, min(384 / image.extent.width, 1536 / image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = pixelContext.createCGImage(small, from: small.extent),
              let scan = ChatOCRScanContext.make(from: cgImage) else { return observations }
        return observations.map { observation in
            // Header and input/keyboard pixels are not speaker evidence.
            guard observation.box.minY >= 0.11, observation.box.maxY <= 0.94,
                  let evidence = ChatBubbleScanner.evidence(
                    forText: ChatLayoutBox(x: Double(observation.box.minX), y: Double(observation.box.minY),
                        width: Double(observation.box.width), height: Double(observation.box.height)),
                    rows: scan.rows, background: scan.background) else { return observation }
            let avatar: LiveChatBubbleHint.AvatarSide
            switch evidence.avatarSide {
            case .left: avatar = .left
            case .right: avatar = .right
            case .none: avatar = .none
            }
            var enriched = observation
            enriched.bubble = LiveChatBubbleHint(minX: CGFloat(evidence.span.minX), maxX: CGFloat(evidence.span.maxX),
                isGreen: evidence.span.tone == .greenish, avatarSide: avatar)
            return enriched
        }
    }
}
