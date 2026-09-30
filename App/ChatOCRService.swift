import CoreGraphics
import Foundation
import Vision

#if canImport(UIKit)
import UIKit
#endif

// MARK: - 结果 / 错误

/// 一次识别的结果。lines 的 box 一律是**原图归一化、左上原点**坐标
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

// MARK: - 气泡扫描用的低分辨率像素

/// 给 ChatBubbleScanner 用的分析图：几百像素宽的 RGBA 采样。
///
/// 只为了量「气泡边缘在哪」，不为读字，所以可以缩得很小（1 像素约 0.3% 宽度）。
/// 内存和长图高度无关地受控：宽 384 的分析图，最高的一张长图也才几 MB。
struct ChatOCRScanContext {
    let rows: ChatPixelRows
    let background: ChatRGB

    /// 从**工作图**（已经缩放、方向已摆正的那张）建分析图。
    ///
    /// 工作图归一化坐标和原图归一化坐标在均匀缩放下**完全相等**，
    /// 所以扫描结果可以直接和换算后的文字框同口径使用，不需要再做一次坐标变换。
    static func make(from image: CGImage, targetWidth: Int = ChatOCRService.analysisWidth) -> ChatOCRScanContext? {
        guard image.width >= 1, image.height >= 1 else { return nil }
        let width = max(1, min(targetWidth, image.width))
        let ratio = Double(width) / Double(image.width)
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        // 护栏：分析图再大也不该超过这个像素数（正常最多 384 × 几千）。
        guard width * height <= 8_000_000 else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .medium
            // 位图上下文的内存第 0 行就是图像顶行，所以不需要翻转：
            // 直接 draw 出来的缓冲区行序和 ChatPixelRows 的左上原点口径一致。
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var pixels: [ChatRGB] = []
        pixels.reserveCapacity(width * height)
        var index = 0
        while index + 3 < buffer.count {
            pixels.append(
                ChatRGB(
                    byteRed: buffer[index],
                    byteGreen: buffer[index + 1],
                    byteBlue: buffer[index + 2]
                )
            )
            index += 4
        }
        guard let rows = ChatPixelRows(width: width, height: height, pixels: pixels) else {
            return nil
        }
        guard let background = ChatBubbleScanner.background(of: rows) else { return nil }
        return ChatOCRScanContext(rows: rows, background: background)
    }
}

// MARK: - 服务

/// 本机 OCR：VNRecognizeTextRequest + .accurate + 简体中文/英文。
///
/// 隐私边界（本文件是唯一碰截图的地方）：
/// - 图片只在内存里过一遍，**不落盘、不上传、不打印**；
/// - 只返回文字、归一化框、置信度和「气泡左右边缘」这类几何量，不返回图片本身；
/// - 不读剪贴板，不写剪贴板。
///
/// 长截图怎么处理（这是本文件的核心）：
/// 整图把最长边压到 2400 像素时，1290×12000 的长截图宽度只剩 258 像素，
/// 聊天文字会糊到认不出来。所以改成：
/// 1. ChatOCRTilingPlanner 先按「最长边不超上限」算缩放，**如果宽度掉到不可读就退回按宽度定比例**；
/// 2. 高度还超上限时竖着切若干片，**一次只渲染并识别一片**（峰值内存 ≈ 一片）；
/// 3. 每片的 Vision 结果用 ChatOCRCoordinateMapper 换算回原图归一化坐标；
/// 4. 分片重叠区的重复文字用 ChatOCRLineDeduplicator 去掉；
/// 5. 再从工作图采一张几百像素宽的分析图，给每一行补上**所在气泡**的左右边缘
///    （角色判定靠它，不靠文字框宽度）。
enum ChatOCRService {

    /// 简体中文 + 英文混排。
    static let defaultLanguageHints = ["zh-Hans", "en-US"]

    /// 缩放 / 分片的全部参数（唯一一处定义）。
    static let defaultTiling = ChatOCRTilingConfig.default

    /// 气泡扫描分析图的宽度。够定位边缘，又不会让内存跟着长图涨。
    static let analysisWidth = 384

    // MARK: 入口

#if canImport(UIKit)
    /// 同步版本。Vision 的 perform 是阻塞的，**不要在主线程调用它**。
    static func recognizeSync(
        image: UIImage,
        tiling: ChatOCRTilingConfig = ChatOCRService.defaultTiling,
        languageHints: [String] = ChatOCRService.defaultLanguageHints
    ) throws -> ChatOCRResult {
        try recognizeSync(
            pixelSize: orientedPixelSize(of: image),
            render: { target in redraw(image, to: target) },
            tiling: tiling,
            languageHints: languageHints
        )
    }

    /// 给 SwiftUI 用的异步版本：内部丢到后台队列，不占主线程。
    ///
    /// 说明一处**诚实的限制**：VNImageRequestHandler.perform 是同步阻塞调用，
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
#endif

    /// 已经摆正的位图入口。CI 上的真实 Vision 合成测试走这里，
    /// 走的和 App 完全同一套识别 / 换算 / 扫描 / 去重代码。
    static func recognizeSync(
        cgImage: CGImage,
        tiling: ChatOCRTilingConfig = ChatOCRService.defaultTiling,
        languageHints: [String] = ChatOCRService.defaultLanguageHints
    ) throws -> ChatOCRResult {
        try recognizeSync(
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            render: { target in render(cgImage, to: target) },
            tiling: tiling,
            languageHints: languageHints
        )
    }

    /// 唯一的实现：pixelSize 是原图像素尺寸，render 负责把原图渲染成指定尺寸的正立位图。
    static func recognizeSync(
        pixelSize: CGSize,
        render: (CGSize) -> CGImage?,
        tiling: ChatOCRTilingConfig = ChatOCRService.defaultTiling,
        languageHints: [String] = ChatOCRService.defaultLanguageHints
    ) throws -> ChatOCRResult {
        let plan: ChatOCRTilingPlan
        do {
            plan = try ChatOCRTilingPlanner.plan(
                pixelWidth: Double(pixelSize.width),
                pixelHeight: Double(pixelSize.height),
                config: tiling
            )
        } catch let error as ChatOCRGeometryError {
            throw serviceError(from: error)
        }

        let workingSize = CGSize(width: plan.workingWidth, height: plan.workingHeight)
        let mapper = ChatOCRCoordinateMapper(plan: plan)

        switch plan.strategy {
        case .singlePass:
            guard let prepared = render(workingSize) else { throw ChatOCRError.invalidImage }
            let scan = ChatOCRScanContext.make(from: prepared)
            let lines = try recognizeLines(
                cgImage: prepared,
                languageHints: languageHints,
                tileOrigin: .zero,
                workingSize: workingSize
            )
            // 走 map（而不是另一套换算）：单次识别就是「原点在 0 的一片」，
            // 这样单次和分片只有一条换算路径，不会各自漂。
            let mapped = mapper.map(lines: lines, tileOrigin: .zero)
            return ChatOCRResult(
                lines: attachBubbleEvidence(to: mapped, scan: scan),
                strategy: .singlePass,
                originalPixelSize: pixelSize
            )

        case .tiled:
            guard let workingImage = render(workingSize) else { throw ChatOCRError.invalidImage }
            let scan = ChatOCRScanContext.make(from: workingImage)
            return try recognizeTiled(
                workingImage: workingImage,
                plan: plan,
                mapper: mapper,
                scan: scan,
                languageHints: languageHints
            )
        }
    }

    // MARK: 分片路线

    private static func recognizeTiled(
        workingImage: CGImage,
        plan: ChatOCRTilingPlan,
        mapper: ChatOCRCoordinateMapper,
        scan: ChatOCRScanContext?,
        languageHints: [String]
    ) throws -> ChatOCRResult {
        let workingSize = CGSize(width: plan.workingWidth, height: plan.workingHeight)
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

        // 换算之后每一行都已经是**原图归一化**坐标，而分析图的归一化坐标和它相等，
        // 所以气泡扫描可以直接用换算后的框，不需要再做一次变换。
        let deduplicated = ChatOCRLineDeduplicator.removingOverlapDuplicates(collected)
        return ChatOCRResult(
            lines: attachBubbleEvidence(to: deduplicated, scan: scan),
            strategy: .tiled,
            originalPixelSize: CGSize(width: plan.originalWidth, height: plan.originalHeight)
        )
    }

    // MARK: 气泡证据

    /// 给每一行补上「这一行在哪个气泡里、气泡左右边缘在哪、头像在哪一侧」。
    ///
    /// 扫不出来就原样返回（那一行会退回「文字框贴边」的老口径），不会因为扫不到就瞎判。
    private static func attachBubbleEvidence(
        to lines: [ChatOCRLine],
        scan: ChatOCRScanContext?
    ) -> [ChatOCRLine] {
        guard let scan = scan else { return lines }
        return lines.map { line in
            guard let evidence = ChatBubbleScanner.evidence(
                forText: line.box,
                rows: scan.rows,
                background: scan.background
            ) else {
                return line
            }
            return ChatOCRLine(
                text: line.text,
                box: line.box,
                confidence: line.confidence,
                bubble: evidence
            )
        }
    }

    // MARK: Vision

    /// 识别一张（整图或一片）已经渲染好的位图。
    ///
    /// tileOrigin 是这片在**工作图里的像素起点**，workingSize 是整张工作图的像素尺寸。
    /// Vision 的 boundingBox 是相对传入位图的归一化坐标，这里要换算成
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
        if #available(iOS 16.0, macOS 13.0, *) {
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
            let text = ocrTrimmed(candidate.string)
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
    /// 关键：除以的是 workingWidth/workingHeight（整张工作图），不是单片的像素尺寸。
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

    /// 把 CGImage 渲染成指定尺寸的正立位图（纯 CoreGraphics，macOS 上也能跑）。
    private static func render(_ image: CGImage, to target: CGSize) -> CGImage? {
        let width = max(1, Int(target.width.rounded()))
        let height = max(1, Int(target.height.rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .high
        // 深色截图带透明通道时，垫白底比留黑底更接近人眼看到的对比。
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

#if canImport(UIKit)
    /// 把 EXIF 方向烧进像素后的原始像素尺寸。
    private static func orientedPixelSize(of image: UIImage) -> CGSize {
        let size = image.size
        let scale = image.scale > 0 ? image.scale : 1
        return CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    }

    /// 重画一遍：一次解决三件事 —— 缩放、把 EXIF 方向烧进像素、拿到确定的位图。
    ///
    /// 缩放比例由 ChatOCRTilingPlanner 算好，这里只负责照做（不在这个文件里再定一套口径）。
    /// 直接画到目标尺寸、不经过全尺寸中间图，长截图的内存才守得住。
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
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelTarget))
            image.draw(in: CGRect(origin: .zero, size: pixelTarget))
        }
        return redrawn.cgImage
    }
#endif

    /// 从工作图里裁一片。tile 是工作图像素坐标，已经保证落在图内。
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

/// 自带一份 trim，不用 GoutouConfig.swift 里那份 String.trimmed：
/// 那个文件不在 CI 的独立编译范围里，自己带着才能单飞。
private func ocrTrimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}
