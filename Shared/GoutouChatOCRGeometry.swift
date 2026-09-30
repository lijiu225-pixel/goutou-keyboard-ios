import Foundation

// MARK: - 长截图分片识别的纯几何部分
//
// 这个文件**刻意只依赖 Foundation**（和 `ChatLayoutParser.swift` 同样的理由）：
// CI 上可以把它和 `tools/ChatLayoutCheck/main.swift` 一起用 `swiftc` 单独编译运行，
// 不需要模拟器、不需要 Vision / UIKit。真正的 Vision 调用在 `App/ChatOCRService.swift` 里，
// 那份代码只负责「按这里的计划裁图、识别、把结果交给这里换算」。
//
// 坐标口径（从头到尾只有一种，写清楚免得来回换算出错）：
// - **原图像素**：`ChatPixelRect`，左上原点，单位是原图像素（EXIF 方向已经烧进像素）。
// - **归一化**：`ChatLayoutBox`，左上原点，值域 0...1，相对于**原图**。
// - 缩放后的工作图：`workingWidth/workingHeight` 像素，同样左上原点；
//   换算用 `ChatOCRCoordinateMapper`，它是唯一做这一步的地方。
//
// 「分片」要解决的具体问题：整图把最长边压到 2400 像素时，长截图（例如 1290×12000）
// 的宽会被压到 258 像素，聊天文字直接糊掉。分片改成**按宽度优先定缩放**，
// 竖着切几片分别识别，再把坐标换算回原图。

/// 像素矩形。左上原点，单位是像素。
struct ChatPixelRect: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var area: Double { max(0, width) * max(0, height) }

    /// 裁到画布范围内，并至少留 1×1 像素（Vision 不吃零尺寸）。
    func clipped(toWidth canvasWidth: Double, height canvasHeight: Double) -> ChatPixelRect {
        let left = min(max(x, 0), max(canvasWidth, 0))
        let top = min(max(y, 0), max(canvasHeight, 0))
        let right = min(max(maxX, 0), max(canvasWidth, 0))
        let bottom = min(max(maxY, 0), max(canvasHeight, 0))
        return ChatPixelRect(
            x: left,
            y: top,
            width: max(right - left, 1),
            height: max(bottom - top, 1)
        )
    }
}

/// 缩放与切片的全部可调参数。默认值就是「支持范围」的定义，改这里即可。
struct ChatOCRTilingConfig: Equatable {
    /// 单次识别允许的最长边（像素）。超过就降采样或切片。
    var maxPixelDimension: Double = 2400
    /// 任何一维都不许低于这个值——宽度低于它，聊天文字就不可读了。
    var minimumPixelDimension: Double = 480
    /// 分片时每一片的高度（像素）。
    var tileSpan: Double = 1400
    /// 最多切几片。超过就判定「图太长，支持不了」，明确报错而不静默降质。
    var maxTileCount: Int = 60
    /// 原图像素总数上限（内存护栏）。
    var maxPixelCount: Double = 64_000_000

    static let `default` = ChatOCRTilingConfig()
}

/// 一次识别要走的路线。`Equatable` 方便测试直接断言分支。
enum ChatOCRStrategy: Equatable {
    /// 图不大：原图（或轻微降采样后）一次识别完。
    case singlePass
    /// 长图：按 `tiles` 顺序分片识别。
    case tiled
}

/// 图片超出支持范围时抛出，界面照原文提示用户，不静默降质。
enum ChatOCRGeometryError: LocalizedError, Equatable {
    case emptyImage
    case tooManyPixels(pixels: Double, limit: Double)
    case tooTall(pixelHeight: Double, tileCount: Int)
    case widthTooSmall(pixelWidth: Double, minimum: Double)

    var errorDescription: String? {
        switch self {
        case .emptyImage:
            return "这张图没有有效像素，换一张聊天截图。"
        case .tooManyPixels:
            return "这张图太大了，本机内存放不下，换一张截图。建议用聊天软件自带的「长截图」，不要用整屏录制导出的大图。"
        case .tooTall(let pixelHeight, let tileCount):
            return "这张图有 \(Int(pixelHeight)) 像素高，需要切成 \(tileCount) 片，超过本阶段支持的上限。请分段截图（比如一次截半屏），分几次识别。"
        case .widthTooSmall(let pixelWidth, let minimum):
            return "这张图只有 \(Int(pixelWidth)) 像素宽，缩到能识别的尺寸后文字会糊，认不准。请用原始分辨率重新截图。"
        }
    }
}

/// 一张图的识别计划：缩放比例、切几片、每片在原图像素里的位置。
struct ChatOCRTilingPlan: Equatable {
    /// 原图像素尺寸（EXIF 方向已经烧进像素）。
    let originalWidth: Double
    let originalHeight: Double
    /// 工作图缩放比例。`1` 表示不缩放。
    let scale: Double
    /// 缩放后的工作图尺寸（像素）。
    let workingWidth: Double
    let workingHeight: Double
    let strategy: ChatOCRStrategy
    /// 分片在**工作图**坐标系里的位置（裁剪用）。`singlePass` 时为空。
    let tiles: [ChatPixelRect]

    var didDownscale: Bool { scale < 1 }

    /// 支持范围的一句话说明，界面直接展示。
    var supportSummary: String {
        switch strategy {
        case .singlePass:
            return "单次识别（最长边不超过 \(Int(ChatOCRTilingConfig.default.maxPixelDimension)) 像素）"
        case .tiled:
            return "分 \(tiles.count) 片识别，文字按原图分辨率保留"
        }
    }
}

// MARK: - 计划

enum ChatOCRTilingPlanner {

    /// 唯一决定「单次还是分片」的地方。
    ///
    /// 缩放口径（关键修复点）：
    /// - 第一次只按最长边算，保证不超 `maxPixelDimension`；
    /// - 如果这么算出来的宽度低于 `minimumPixelDimension`，就**退回到按最小宽度定比例**，
    ///   宁可片多一点，也不把文字压糊。
    static func plan(
        pixelWidth: Double,
        pixelHeight: Double,
        config: ChatOCRTilingConfig = .default
    ) throws -> ChatOCRTilingPlan {
        guard pixelWidth >= 1, pixelHeight >= 1 else {
            throw ChatOCRGeometryError.emptyImage
        }
        let pixels = pixelWidth * pixelHeight
        guard pixels <= config.maxPixelCount else {
            throw ChatOCRGeometryError.tooManyPixels(pixels: pixels, limit: config.maxPixelCount)
        }

        let longest = max(pixelWidth, pixelHeight)
        var scale = longest > config.maxPixelDimension ? config.maxPixelDimension / longest : 1
        let widthAfterLongestEdge = pixelWidth * scale
        if widthAfterLongestEdge < config.minimumPixelDimension {
            // 长截图走到这里：按最长边缩会把宽度压到不可读，改成按宽度定比例。
            let widthPreservingScale = config.minimumPixelDimension / pixelWidth
            scale = max(scale, min(1, widthPreservingScale))
        }

        let workingWidth = max(1, pixelWidth * scale)
        let workingHeight = max(1, pixelHeight * scale)
        guard workingWidth >= min(config.minimumPixelDimension, pixelWidth) else {
            throw ChatOCRGeometryError.widthTooSmall(
                pixelWidth: pixelWidth,
                minimum: config.minimumPixelDimension
            )
        }

        if workingHeight <= config.maxPixelDimension {
            return ChatOCRTilingPlan(
                originalWidth: pixelWidth,
                originalHeight: pixelHeight,
                scale: scale,
                workingWidth: workingWidth,
                workingHeight: workingHeight,
                strategy: .singlePass,
                tiles: []
            )
        }

        let tiles = tileRects(
            workingWidth: workingWidth,
            workingHeight: workingHeight,
            tileSpan: config.tileSpan
        )
        guard tiles.count <= config.maxTileCount else {
            throw ChatOCRGeometryError.tooTall(pixelHeight: pixelHeight, tileCount: tiles.count)
        }
        return ChatOCRTilingPlan(
            originalWidth: pixelWidth,
            originalHeight: pixelHeight,
            scale: scale,
            workingWidth: workingWidth,
            workingHeight: workingHeight,
            strategy: .tiled,
            tiles: tiles
        )
    }

    /// 从下往上倒着推每一片的起点，保证最后一片正好贴着底边、没有空白片。
    static func tileRects(workingWidth: Double, workingHeight: Double, tileSpan: Double) -> [ChatPixelRect] {
        guard workingWidth >= 1, workingHeight >= 1, tileSpan >= 1 else { return [] }
        let count = max(1, Int(ceil(workingHeight / tileSpan)))
        var rects: [ChatPixelRect] = []
        rects.reserveCapacity(count)
        for index in 0..<count {
            let remaining = count - 1 - index
            let top = max(0, workingHeight - Double(remaining + 1) * tileSpan)
            let rect = ChatPixelRect(
                x: 0,
                y: top,
                width: workingWidth,
                height: min(tileSpan, workingHeight - top)
            )
            rects.append(rect.clipped(toWidth: workingWidth, height: workingHeight))
        }
        return rects
    }
}

// MARK: - 坐标换算

/// 把分片识别结果从工作图坐标系换算回**原图归一化**坐标系。
///
/// 这是分片方案里最容易出错的一步，所以单独成类型并配了测试。
struct ChatOCRCoordinateMapper: Equatable {
    let originalWidth: Double
    let originalHeight: Double
    /// 工作图相对原图的缩放比例。
    let scale: Double

    init(plan: ChatOCRTilingPlan) {
        self.originalWidth = plan.originalWidth
        self.originalHeight = plan.originalHeight
        self.scale = plan.scale
    }

    init(originalWidth: Double, originalHeight: Double, scale: Double) {
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.scale = scale
    }

    /// 把工作图归一化坐标（0...1，左上原点）换成原图归一化坐标。
    ///
    /// 两边都是「归一化」量纲时，缩放比可以直接相乘：
    /// 原图归一化 = 工作图归一化 × (原图边长 / 工作图边长) = 工作图归一化 ÷ scale。
    func normalizedBox(fromWorkingNormalized box: ChatLayoutBox) -> ChatLayoutBox {
        let factor = inverseScale
        return ChatLayoutBox(
            minX: box.minX * factor,
            minY: box.minY * factor,
            maxX: box.maxX * factor,
            maxY: box.maxY * factor
        )
    }

    /// 把一片内的归一化坐标换算回**原图归一化**坐标。
    ///
    /// `tileOrigin` 是这片在**工作图**里的像素起点，`tileSize` 是这片自己的像素尺寸。
    /// 因为 Vision 的坐标是相对「传进去的那张位图」的，所以必须先用这一片的尺寸把
    /// 片内归一化坐标还原成工作图像素，再加上片偏移，最后除以原图边长。
    /// 两步缺一不可：漏掉片偏移，第二片开始的位置会整体偏上；漏掉除以原图边长，
    /// 坐标就不是「原图归一化」口径，后面的左右归属判断全错。
    func map(
        lines: [ChatOCRLine],
        tileOrigin: ChatPixelRect,
        tileSize: CGSize
    ) -> [ChatOCRLine] {
        let width = max(Double(tileSize.width), 1)
        let height = max(Double(tileSize.height), 1)
        return lines.map { line in
            ChatOCRLine(
                text: line.text,
                box: ChatLayoutBox(
                    minX: (line.box.minX * width + tileOrigin.x) * inverseScale / max(originalWidth, 1),
                    minY: (line.box.minY * height + tileOrigin.y) * inverseScale / max(originalHeight, 1),
                    maxX: (line.box.maxX * width + tileOrigin.x) * inverseScale / max(originalWidth, 1),
                    maxY: (line.box.maxY * height + tileOrigin.y) * inverseScale / max(originalHeight, 1)
                ),
                confidence: line.confidence
            )
        }
    }

    /// 工作图坐标 → 原图坐标的乘数。缩得越小，乘数越大（坐标要放大回去）。
    private var inverseScale: Double {
        let effectiveScale = scale > 0 ? scale : 1
        return 1 / effectiveScale
    }

    /// 把一片的识别结果整体换算回原图归一化坐标。
    ///
    /// `lines` 的 `box` 是工作图归一化坐标；`tileRect` 除了用于裁剪，
    /// 也用来给「结果位置必须落在这一片里」留一个断言空间（测试用）。
    func map(lines: [ChatOCRLine], fromTile tileRect: ChatPixelRect) -> [ChatOCRLine] {
        _ = tileRect
        return lines.map { line in
            ChatOCRLine(
                text: line.text,
                box: normalizedBox(fromWorkingNormalized: line.box),
                confidence: line.confidence
            )
        }
    }
}

// MARK: - 分片重复文字

enum ChatOCRLineMergeDecision: Equatable {
    case keepBoth
    case skipIncoming
    case replaceKept
}

enum ChatOCRLineDeduplicator {

    /// 两行的文本算不算「同一句话」。
    ///
    /// 只有**完全一致**或**互相包含**才算：分片重叠区里同一行文字通常被识别成一模一样，
    /// 偶尔一片少认几个字。不做模糊相似度，宁可留下一行让用户删，
    /// 也不要因为「看起来像」把两句不同的话吃掉。
    static func isSameText(_ lhs: String, _ rhs: String, allowSubstring: Bool = true) -> Bool {
        let left = stripped(lhs)
        let right = stripped(rhs)
        if left.isEmpty || right.isEmpty { return false }
        if left == right { return true }
        guard allowSubstring else { return false }
        return left.contains(right) || right.contains(left)
    }

    /// 两个框是不是「同一行文字的两次识别」。
    ///
    /// 判据很窄，避免把上下紧挨着的两条消息误并：
    /// 纵向要重叠得足够多（相对较矮的那个框），横向中心要基本对齐（相对行高）。
    static func isSameLine(
        _ lhs: ChatLayoutBox,
        _ rhs: ChatLayoutBox,
        minVerticalOverlap: Double = 0.4,
        centerXTolerance: Double = 0.6
    ) -> Bool {
        let shorter = min(lhs.height, rhs.height)
        guard shorter > 0 else { return false }
        let vertical = lhs.verticalOverlap(with: rhs) / shorter
        guard vertical >= minVerticalOverlap else { return false }

        let centerGap = abs(lhs.centerX - rhs.centerX)
        let tolerance = max(shorter, 0.0001) * centerXTolerance
        return centerGap <= tolerance
    }

    /// 重叠区只留一条：先看置信度，再看文字长度（长的说明这一片认全了），最后按原顺序。
    static func mergeDecision(
        kept: ChatOCRLine,
        incoming: ChatOCRLine,
        minVerticalOverlap: Double = 0.4,
        centerXTolerance: Double = 0.6,
        allowSubstring: Bool = true
    ) -> ChatOCRLineMergeDecision {
        guard isSameText(kept.text, incoming.text, allowSubstring: allowSubstring) else {
            return .keepBoth
        }
        guard isSameLine(
            kept.box,
            incoming.box,
            minVerticalOverlap: minVerticalOverlap,
            centerXTolerance: centerXTolerance
        ) else {
            return .keepBoth
        }
        if incoming.confidence != kept.confidence {
            return incoming.confidence > kept.confidence ? .replaceKept : .skipIncoming
        }
        let keptLength = stripped(kept.text).count
        let incomingLength = stripped(incoming.text).count
        if incomingLength != keptLength {
            return incomingLength > keptLength ? .replaceKept : .skipIncoming
        }
        // 完全相同、置信度也一样：留先来的（分片是从上到下处理的，先来的在上面）。
        return .skipIncoming
    }

    /// 去掉分片重叠造成的重复文字，**保留下来的行的相对顺序和输入完全一致**。
    ///
    /// 用「先定去留、再按原顺序过滤」两步，而不是就地增删：
    /// 就地删改会把被判为更优的那一条挪到数组末尾，分片的阅读顺序就被打乱了。
    /// 平手（文字和置信度都一样）时留先来的——分片是从上到下处理的，先来的在上面。
    static func removingOverlapDuplicates(
        _ lines: [ChatOCRLine],
        minVerticalOverlap: Double = 0.4,
        centerXTolerance: Double = 0.6,
        allowSubstring: Bool = true
    ) -> [ChatOCRLine] {
        guard lines.count > 1 else { return lines }
        var dropped = [Bool](repeating: false, count: lines.count)
        for index in lines.indices where !dropped[index] {
            let incoming = lines[index]
            var previous = 0
            while previous < index {
                if !dropped[previous] {
                    switch mergeDecision(
                        kept: lines[previous],
                        incoming: incoming,
                        minVerticalOverlap: minVerticalOverlap,
                        centerXTolerance: centerXTolerance,
                        allowSubstring: allowSubstring
                    ) {
                    case .keepBoth:
                        break
                    case .skipIncoming:
                        dropped[index] = true
                        // 已经出局，不用再和更早的比。
                        previous = index
                        continue
                    case .replaceKept:
                        dropped[previous] = true
                    }
                }
                previous += 1
            }
        }
        return lines.enumerated().filter { !dropped[$0.offset] }.map { $0.element }
    }

    private static func stripped(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
