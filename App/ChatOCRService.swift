import CoreGraphics
import UIKit
import Vision

// MARK: - 结果 / 错误

/// 一次识别的结果。`lines` 的 `box` 一律是**原图归一化、左上原点**坐标
/// （单次识别和分片识别出来的口径完全一样，后面的版式判断不需要关心走过哪条路线）。
struct ChatOCRResult {
    let lines: [ChatOCRLine]
    /// 实际走的是单次识别还是分片识别，界面据此说明「文字按原图分辨率保留」。
    let strategy: ChatOCRStrategy
    /// 实际处理（渲染）的原图像素尺寸，给界面提示用。
    let originalPixelSize: CGSize

    var isEmpty: Bool { lines.isEmpty }
}

enum ChatOCRError: LocalizedError, Equatable {
    case invalidImage
    case unsupportedImage(String)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "这张图读不出像素内容，换一张再试。"
        case .unsupportedImage(let reason):
            // reason 是我们自己写的支持范围说明，不含图片内容。
            return reason
        case .recognitionFailed(let reason):
            // reason 是系统给的短描述，不含图片内容。
            return "本机识别失败：\(reason)"
        }
    }
}

// MARK: - 服务

/// 本机 OCR：`VNRecognizeTextRequest` + `.accurate` + 简体中文/英文。
///
/// 隐私边界（本文件是唯一碰截图的地方）：
/// - 图片只在内存里过一遍，**不落盘、不上传、不打印**；
/// - 只返回文字、归一化框和置信度，不返回图片本身；
/// - 不读剪贴板，不写剪贴板。
///
/// 长截图怎么处理（这是本文件的核心）：
/// 整图把最长边压到 2400 像素时，1290×12000 的长截图宽度只剩 258 像素，
/// 聊天文字会糊到认不出来。所以改成：
/// 1. `ChatOCRTilingPlanner` 先按「最长边不超上限」算缩放，**如果宽度掉到不可读就退回按宽度定比例**；
/// 2. 高度还超上限时竖着切若干片，**一次只渲染并识别一片**（峰值内存 ≈ 一片）；
/// 3. 每片的 Vision 结果用 `ChatOCRCoordinateMapper` 换算回原图归一化坐标；
/// 4. 分片重叠区的重复文字用 `ChatOCRLineDeduplicator` 去掉。
/// 路线判定的几何、换算和去重都在 `Shared/GoutouChatOCRGeometry.swift` 里，是纯 Foundation，有测试。
enum ChatOCRService {

    /// 简体中文 + 英文混排。
    static let defaultLanguageHints = ["zh-Hans", "en-US"]

    /// 缩放 / 分片的全部参数（唯一一处定义）。
    static let defaultTiling = ChatOCRTilingConfig.default

    /// 同步版本。`Vision` 的 `perform` 是阻塞的，**不要在主线程调用它**。
    static func recognizeSync(
        image: UIImage,
        tiling: ChatOCRTilingConfig = ChatOCRService.defaultTiling,
        languageHints: [String] = ChatOCRService.defaultLanguageHints
    ) throws -> ChatOCRResult {
        let pixelSize = orientedPixelSize(of: image)
        let plan: ChatOCRTilingPlan
        do {
            plan = try ChatOCRTilingPlanner.plan(
                pixelWidth: pixelSize.width,
                pixelHeight: pixelSize.height,
                config: tiling
            )
        } catch let error as ChatOCRGeometryError {
            throw serviceError(from: error)
        }

        switch plan.strategy {
        case .singlePass:
            let prepared = redraw(image, to: CGSize(width: plan.workingWidth, height: plan.workingHeight))
            guard let prepared else { throw ChatOCRError.invalidImage }
            let lines = try recognizeLines(
                cgImage: prepared,
                languageHints: languageHints,
                tileOrigin: .zero,
                workingSize: CGSize(width: plan.workingWidth, height: plan.workingHeight)
            )
            let mapper = ChatOCRCoordinateMapper(plan: plan)
            let mapped = lines.map { line in
                ChatOCRLine(
                    text: line.text,
                    box: mapper.normalizedBox(fromWorkingNormalized: line.box),
                    confidence: line.confidence
                )
            }
            return ChatOCRResult(lines: mapped, strategy: .singlePass, originalPixelSize: pixelSize)

        case .tiled:
            return try recognizeTiled(
                image: image,
                plan: plan,
                languageHints: languageHints
            )
        }
    }

    /// 给 SwiftUI 用的异步版本：内部丢到后台队列，不占主线程。
    ///
    /// 说明一处**诚实的限制**：`VNImageRequestHandler.perform` 是同步阻塞调用，
    /// 中途没法打断；这里能保证的是「片与片之间可以取消」。
    /// 也就是说取消后最多再白跑完当前这一片，**不会**再更新任何界面状态。
    static func recognize(
        image: UIImage,
        tiling: ChatOCRTilingConfig = ChatOCRService.defaultTiling,
        languageHints: [String] = ChatOCRService.defaultLanguageHints
    ) async throws -> ChatOCRResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ChatOCRResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try recognizeSync(
                        image: image,
                        tiling: tiling,
                        languageHints: languageHints
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: 分片路线

    private static func recognizeTiled(
        image: UIImage,
        plan: ChatOCRTilingPlan,
        languageHints: [String]
    ) throws -> ChatOCRResult {
        let workingSize = CGSize(width: plan.workingWidth, height: plan.workingHeight)
        guard let workingImage = redraw(image, to: workingSize) else {
            throw ChatOCRError.invalidImage
        }

        let mapper = ChatOCRCoordinateMapper(plan: plan)
        var collected: [ChatOCRLine] = []

        for (offset, tile) in plan.tiles.enumerated() {
            // 片与片之间是唯一的取消检查点（片内是同步阻塞的 Vision 调用，打断不了）。
            if offset > 0 {
                try Task.checkCancellation()
            }
            guard let tileImage = crop(workingImage, to: tile) else { continue }
            let lines = try recognizeLines(
                cgImage: tileImage,
                languageHints: languageHints,
                tileOrigin: tile,
                workingSize: workingSize
            )
            // 片内按上→下、左→右排一遍（Vision 的结果顺序没有承诺），
            // 片与片之间本来就是从上往下处理的，这样收集顺序就是阅读顺序。
            let ordered = lines.enumerated().sorted { lhs, rhs in
                if lhs.element.box.minY != rhs.element.box.minY {
                    return lhs.element.box.minY < rhs.element.box.minY
                }
                if lhs.element.box.minX != rhs.element.box.minX {
                    return lhs.element.box.minX < rhs.element.box.minX
                }
                return lhs.offset < rhs.offset
            }.map { $0.element }
            collected.append(
                contentsOf: mapper.map(
                    lines: ordered,
                    tileOrigin: ChatPixelRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)
                )
            )
        }

        return ChatOCRResult(
            lines: ChatOCRLineDeduplicator.removingOverlapDuplicates(collected),
            strategy: .tiled,
            originalPixelSize: CGSize(width: plan.originalWidth, height: plan.originalHeight)
        )
    }

    // MARK: Vision

    /// 识别一张（整图或一片）已经渲染好的位图。
    ///
    /// `tileOrigin` 是这片在**工作图里的像素起点**，`workingSize` 是整张工作图的像素尺寸。
    /// Vision 的 `boundingBox` 是相对传入位图的归一化坐标，这里要换算成
    /// 「相对整张工作图、左上原点」的口径，所以片偏移和工作图尺寸都得传进来。
    private static func recognizeLines(
        cgImage: CGImage,
        languageHints: [String],
        tileOrigin: ChatPixelRect,
        workingSize: CGSize
    ) throws -> [ChatOCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languageHints
        // 我们本来就要中英混排，自动检测语言只会多花时间。
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = false
        }

        // 像素已经是「方向烧进去」的正立图，所以这里固定 .up。
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ChatOCRError.recognitionFailed(error.localizedDescription)
        }

        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmed
            guard !text.isEmpty else { return nil }
            return ChatOCRLine(
                text: text,
                box: box(
                    fromVisionBoundingBox: observation.boundingBox,
                    workingWidth: Double(workingSize.width),
                    workingHeight: Double(workingSize.height),
                    origin: tileOrigin
                ),
                confidence: candidate.confidence
            )
        }
    }

    // MARK: 坐标转换

    /// Vision（左下原点，相对传进去的那张位图）→ 我们的口径（左上原点，**相对整张工作图归一化**）。
    ///
    /// 关键：除以的是 `workingWidth/workingHeight`（整张工作图），不是单片的像素尺寸。
    /// 用片尺寸做分母会把每一片纵向拉伸（1200 高的片被当成整图高，结果整体偏下、行高翻几倍）。
    static func box(
        fromVisionBoundingBox rect: CGRect,
        workingWidth: Double,
        workingHeight: Double,
        origin: ChatPixelRect
    ) -> ChatLayoutBox {
        let width = max(workingWidth, 1)
        let height = max(workingHeight, 1)
        return ChatLayoutBox(
            minX: Double(rect.minX) + origin.x / width,
            minY: Double(1 - rect.maxY) + origin.y / height,
            maxX: Double(rect.maxX) + origin.x / width,
            maxY: Double(1 - rect.minY) + origin.y / height
        )
    }

    // MARK: 图片预处理

    /// 把 EXIF 方向烧进像素后的原始像素尺寸。
    private static func orientedPixelSize(of image: UIImage) -> CGSize {
        let size = image.size
        let scale = image.scale > 0 ? image.scale : 1
        return CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    }

    /// 重画一遍：一次解决三件事 —— 缩放、把 EXIF 方向烧进像素、拿到确定的位图。
    ///
    /// 缩放比例由 `ChatOCRTilingPlanner` 算好，这里只负责照做（不在这个文件里再定一套口径）。
    private static func redraw(_ image: UIImage, to target: CGSize) -> CGImage? {
        let pixelTarget = CGSize(
            width: max(1, target.width.rounded()),
            height: max(1, target.height.rounded())
        )

        let format = UIGraphicsImageRendererFormat.default()
        // 1:1 像素，别让 scale 偷偷放大三倍。
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelTarget, format: format)
        let redrawn = renderer.image { context in
            // 深色截图带透明通道时，垫白底比留黑底更接近人眼看到的对比。
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelTarget))
            image.draw(in: CGRect(origin: .zero, size: pixelTarget))
        }
        return redrawn.cgImage
    }

    /// 从工作图里裁一片。`tile` 是工作图像素坐标，已经保证落在图内。
    private static func crop(_ image: CGImage, to tile: ChatPixelRect) -> CGImage? {
        let rect = CGRect(
            x: tile.x.rounded(.down),
            y: tile.y.rounded(.down),
            width: max(1, tile.width.rounded()),
            height: max(1, tile.height.rounded())
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return image.cropping(to: rect)
    }

    // MARK: 错误映射

    /// 支持范围的问题照原文告诉用户，不要含糊成「识别失败」。
    private static func serviceError(from error: ChatOCRGeometryError) -> ChatOCRError {
        switch error {
        case .emptyImage:
            return .invalidImage
        case .tooManyPixels, .tooTall, .widthTooSmall:
            return .unsupportedImage(error.localizedDescription)
        }
    }
}
