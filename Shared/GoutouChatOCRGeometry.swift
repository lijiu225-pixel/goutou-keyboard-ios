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

    /// 单次识别（整张图当一片）用的原点。
    static let zero = ChatPixelRect(x: 0, y: 0, width: 0, height: 0)

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
            return "这张图只有 \(Int(pixelWidth)) 像素宽，缩到能识别的尺寸（宽度至少 \(Int(minimum)) 像素）后文字会糊，认不准。请用原始分辨率重新截图。"
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
    /// - 先按「最长边不超 `maxPixelDimension`」算一个比例；
    /// - 这个比例会让宽度掉到 `minimumPixelDimension` 以下时，才改成**按最小宽度定比例**（少缩一点）。
    ///
    /// 两个坑都在这里踩过，注释留着免得再踩：
    /// - `max(scale, 480 / pixelWidth)`：`scale` 是「最多能缩到多少」，480/pw 是「至少缩到多少」，
    ///   取 max 会让缩放比变小，等于把图缩得更狠（1290×12000 会变成宽度正好 480）。
    /// - 不看条件就套 `480 / pixelWidth`：1290×5000 的 2400 高上限已经让宽度保住 619 像素了，
    ///   再套一次反而把它缩到 480，白白降质。
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
            // 不放大（`min(1, ...)`）：原图本来就窄的情况由下面的宽度检查负责报错。
            scale = min(1, config.minimumPixelDimension / pixelWidth)
        }

        let workingWidth = max(1, pixelWidth * scale)
        let workingHeight = max(1, pixelHeight * scale)
        // 宽度保护只保证「不放大」，救不回本来就窄的图（200 像素宽不可能变清楚）。
        // 与其按 200 像素宽硬识（结果一定是错的，用户还得多删），不如直接说清楚。
        guard workingWidth >= config.minimumPixelDimension else {
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

    /// 把工作图竖着切成连续的若干片：层高尽量取 `tileSpan`，除不尽时把余数摊平，
    /// 保证「第一片从 0 开始、片片相接、最后一片正好贴底」，而且没有空白片。
    ///
    /// 曾经写成「从下往上倒推 `H - (remaining+1) × span`」，那只在 H 正好是 span 整数倍时成立：
    /// H=4465.116、span=1400 时会算出第 1 片 y=0 h=1400、第 2 片 y=265.116，
    /// 两片直接叠在一起，中间那一大段永远识别不到。
    static func tileRects(workingWidth: Double, workingHeight: Double, tileSpan: Double) -> [ChatPixelRect] {
        guard workingWidth >= 1, workingHeight >= 1, tileSpan >= 1 else { return [] }
        let count = max(1, Int(ceil(workingHeight / tileSpan)))
        // 平均层高。除不尽时各片高度最多相差 1 像素，无所谓；
        // 关键是它一定 ≤ tileSpan，所以每片都还在 Vision 舒服的范围内。
        let slice = workingHeight / Double(count)

        var rects: [ChatPixelRect] = []
        rects.reserveCapacity(count)
        for index in 0..<count {
            let top = slice * Double(index)
            // 除了最后一片都按 slice 取，最后一片直接取到 H：
            // 用乘法算 `slice × (index+1)` 会积累浮点误差，让最后一片差几个 ulp 贴不住底边。
            let bottom = index == count - 1 ? workingHeight : slice * Double(index + 1)
            let rect = ChatPixelRect(
                x: 0,
                y: top,
                width: workingWidth,
                height: bottom - top
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
    /// 缩放后的工作图尺寸。**换算必须用它做分母**，不能用单片的尺寸 ——
    /// 片内归一化坐标是相对整张工作图归一化出来的，用片高做分母会把每一片纵向拉伸
    /// （1200 高的片会被拉成 6000 高，位置和行高全错）。
    let workingWidth: Double
    let workingHeight: Double
    /// 工作图相对原图的缩放比例。
    let scale: Double

    init(plan: ChatOCRTilingPlan) {
        self.originalWidth = plan.originalWidth
        self.originalHeight = plan.originalHeight
        self.workingWidth = plan.workingWidth
        self.workingHeight = plan.workingHeight
        self.scale = plan.scale
    }

    init(originalWidth: Double, originalHeight: Double, workingWidth: Double, workingHeight: Double, scale: Double) {
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.workingWidth = workingWidth
        self.workingHeight = workingHeight
        self.scale = scale
    }

    /// 把工作图归一化坐标（0...1，左上原点）换成原图归一化坐标。
    ///
    /// **系数是 1**：两边都是「相对自己边长的归一化」，均匀缩放不改变归一化坐标。
    /// 推导：工作图 = 原图 × scale，所以
    /// x_原图归一化 = x_工作图像素 / scale / 原图宽 = x_工作图像素 / 工作图宽 = x_工作图归一化。
    ///
    /// 这里曾经乘 1/scale —— 那是把「归一化」当成「像素」算了一遍，
    /// 于是**任何被降采样的普通截图**（例如 1290×2796 缩到高 2400）整张图的内容
    /// 都会被放大到右下角，贴边的框直接跑出 0...1。单次识别现在也走 map(lines:tileOrigin:.zero)，
    /// 这条换算只作为口径说明保留。
    func normalizedBox(fromWorkingNormalized box: ChatLayoutBox) -> ChatLayoutBox {
        box
    }

    /// 把一片的识别结果换算回**原图归一化**坐标。
    ///
    /// `tileOrigin` 是这片在**工作图**里的像素起点。Vision 给的是「相对传进去那张位图」
    /// 的归一化坐标，所以先用**工作图**尺寸还原成工作图像素、加上片偏移，再换算回原图。
    /// 用片尺寸当分母是错的（见 `workingHeight` 上的注释）。
    func map(lines: [ChatOCRLine], tileOrigin: ChatPixelRect) -> [ChatOCRLine] {
        let factor = inverseScale
        let workingW = max(workingWidth, 1)
        let workingH = max(workingHeight, 1)
        let originalW = max(originalWidth, 1)
        let originalH = max(originalHeight, 1)
        return lines.map { line in
            ChatOCRLine(
                text: line.text,
                box: ChatLayoutBox(
                    minX: (line.box.minX * workingW + tileOrigin.x) * factor / originalW,
                    minY: (line.box.minY * workingH + tileOrigin.y) * factor / originalH,
                    maxX: (line.box.maxX * workingW + tileOrigin.x) * factor / originalW,
                    maxY: (line.box.maxY * workingH + tileOrigin.y) * factor / originalH
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
    /// 判据要窄，但不能窄到认不出同一行：
    /// - 纵向要重叠得足够多（相对较矮的那个框）；
    /// - 横向重叠要占**较窄那个框**的相当一部分。
    ///
    /// 横向**不能**用「中心点距离」：同一行文字被两片各认了一次时，两边认出的片段长短常常不同
    /// （一片只认到半句），框宽跟着变，中心点能差出半个框宽；而上下紧挨的两条消息本来就不同文本，
    /// 靠文本那一关就挡住了，不需要再靠中心点。重叠比例对这两种情形都判得准。
    static func isSameLine(
        _ lhs: ChatLayoutBox,
        _ rhs: ChatLayoutBox,
        minVerticalOverlap: Double = 0.4,
        minHorizontalOverlap: Double = 0.3
    ) -> Bool {
        let shorterHeight = min(lhs.height, rhs.height)
        guard shorterHeight > 0 else { return false }
        let vertical = lhs.verticalOverlap(with: rhs) / shorterHeight
        guard vertical >= minVerticalOverlap else { return false }

        let narrowerWidth = min(lhs.width, rhs.width)
        guard narrowerWidth > 0 else { return false }
        let horizontal = lhs.horizontalOverlap(with: rhs) / narrowerWidth
        return horizontal >= minHorizontalOverlap
    }

    /// 重叠区只留一条：先看置信度，再看文字长度（长的说明这一片认全了），最后按原顺序。
    static func mergeDecision(
        kept: ChatOCRLine,
        incoming: ChatOCRLine,
        minVerticalOverlap: Double = 0.4,
        minHorizontalOverlap: Double = 0.3,
        allowSubstring: Bool = true
    ) -> ChatOCRLineMergeDecision {
        guard isSameText(kept.text, incoming.text, allowSubstring: allowSubstring) else {
            return .keepBoth
        }
        guard isSameLine(
            kept.box,
            incoming.box,
            minVerticalOverlap: minVerticalOverlap,
            minHorizontalOverlap: minHorizontalOverlap
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
        minHorizontalOverlap: Double = 0.3,
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
                        minHorizontalOverlap: minHorizontalOverlap,
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
