import Foundation

// MARK: - 气泡扫描（纯逻辑）
//
// 这个文件只依赖 Foundation：CI 上可以和 tools/ChatLayoutCheck/main.swift 一起用
// swiftc 单独编译运行，不需要模拟器、不需要 CoreGraphics / Vision / UIKit。
// 真正把 CGImage 变成 ChatPixelRows 的代码在 App/ChatOCRService.swift 里。
//
// 为什么需要它（这是第二阶段的核心修复点）：
// 上一阶段的角色判定直接拿 Vision 的文字框当气泡用。但文字框只是「这一行字的墨迹范围」，
// 长句会把文字框撑到几乎和气泡一样宽、短句又只占气泡中间一小段，
// 所以「文字框贴左边 = 对方」这类判据在长句上必然失效。
// 真机上量出来的数字（微信浅色主题、1280x2781，坐标是相对整图的归一化值）：
//   - 右侧绿气泡：气泡右边缘稳定在 0.8664（6 条全部一样），文字右边缘在 0.82 上下飘；
//   - 左侧白气泡：气泡左边缘稳定在 0.1340（5 条全部一样），文字左边缘随句子长短变化。
// 也就是说只有气泡边缘对「谁说的」有判别力，文字框没有。
//
// 这里做的事：把图像降采样成一行行归一化颜色，先估出画布底色，再把「明显不是底色」的列找出来，
// 从而拿到每一行文字所在气泡的左右边缘。用底色而不是「绿色」当判据，
// 是为了深色模式、白气泡、自定义主题都能走同一条路。

/// 归一化 RGB（0...1）。用 Double 不用 UInt8，阈值判定才不会来回取整。
struct ChatRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(byteRed: UInt8, byteGreen: UInt8, byteBlue: UInt8) {
        self.init(
            red: Double(byteRed) / 255,
            green: Double(byteGreen) / 255,
            blue: Double(byteBlue) / 255
        )
    }

    /// 「偏绿」= 绿通道明显高于红和蓝。
    ///
    /// 微信自己的气泡在浅色（#95EC69 一类）和深色主题下都是绿系，对方的是白/灰（三通道接近），
    /// 所以这一条跨主题都成立。它只是辅助判据：颜色能撬动的只有「两边都贴轨道」这一种僵局。
    var isGreenish: Bool {
        green - max(red, blue) > 0.04
    }

    func distance(to other: ChatRGB) -> Double {
        let redDelta = red - other.red
        let greenDelta = green - other.green
        let blueDelta = blue - other.blue
        return (redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta).squareRoot()
    }
}

/// 一张用来做气泡扫描的小图。
///
/// 行 0 是图像顶部，和 ChatLayoutBox 的左上原点口径一致。
/// 缩到几百像素宽足够定位气泡边缘（1 像素约 0.3% 宽度），又不会让内存跟着长图涨。
struct ChatPixelRows: Equatable {
    let width: Int
    let height: Int
    let pixels: [ChatRGB]

    init?(width: Int, height: Int, pixels: [ChatRGB]) {
        guard width >= 1, height >= 1, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func row(atIndex index: Int) -> [ChatRGB] {
        guard width >= 1, index >= 0, index < height else { return [] }
        let start = index * width
        return Array(pixels[start..<(start + width)])
    }

    /// 归一化 y（0...1，左上原点）落在哪一行。
    func rowIndex(forNormalizedY y: Double) -> Int {
        guard height >= 1 else { return 0 }
        let clamped = min(max(y, 0), 1)
        return min(height - 1, max(0, Int((clamped * Double(height - 1)).rounded())))
    }
}

/// 气泡的底色倾向。只有两种：偏绿的（一般是我）和中性的（一般是对方）。
enum ChatBubbleTone: String, Equatable {
    case greenish
    case neutral
}

/// 一次扫描拿到的气泡横向范围（归一化 0...1）。
struct ChatBubbleSpan: Equatable {
    let minX: Double
    let maxX: Double
    let tone: ChatBubbleTone
    let touchesImageLeftEdge: Bool
    let touchesImageRightEdge: Bool

    var width: Double { max(0, maxX - minX) }
    var centerX: Double { (minX + maxX) / 2 }

    /// 同一气泡的相邻文字行合并：范围取并集，颜色和贴边取「只要有一行成立就成立」。
    func union(_ other: ChatBubbleSpan) -> ChatBubbleSpan {
        ChatBubbleSpan(
            minX: min(minX, other.minX),
            maxX: max(maxX, other.maxX),
            tone: tone == .greenish || other.tone == .greenish ? .greenish : .neutral,
            touchesImageLeftEdge: touchesImageLeftEdge || other.touchesImageLeftEdge,
            touchesImageRightEdge: touchesImageRightEdge || other.touchesImageRightEdge
        )
    }
}

/// 头像出现在气泡的哪一侧。头像是独立的第二块色块，只在判不出轨道时当辅助。
enum ChatAvatarSide: String, Equatable {
    case left
    case right
    case none
}

/// 附着在一行 OCR 结果上的气泡证据。
struct ChatBubbleEvidence: Equatable {
    let span: ChatBubbleSpan
    let avatarSide: ChatAvatarSide
}

struct ChatBubbleScanConfig: Equatable {
    /// 像素离底色多远算「不是底色」。0.06 在真机截图上是这样：
    /// 浅色主题画布 236 与白气泡 255 的距离是 0.122，深色主题画布 17 与对方气泡 44 的距离是 0.183，
    /// 两边都有 2 倍以上余量；而画布自身的 JPEG 噪声只有 0.01 上下。
    var tolerance: Double = 0.06
    /// 小于这个宽度的色块不当气泡（噪声、标点）。
    var minimumSpanWidth: Double = 0.03
    /// 并集里小于这个宽度的缝隙直接补上（文字笔画会把气泡打断）。
    var gapTolerance: Double = 0.006
    /// 每行文字取几个采样行做并集。
    var rowSampleCount: Int = 5
    /// 贴到图像边缘多近算「被裁掉了」。
    var edgeSlack: Double = 0.012
    /// 估底色时每个通道量化成几位。
    var backgroundQuantizationBits: Int = 4
    /// 头像色块的宽度必须落在这个区间里才认。
    var avatarWidthRange: ClosedRange<Double> = 0.03...0.16

    // MARK: 把「气泡」和「裸文字」分开
    //
    // 文字本身也是「非底色」：一行孤零零的居中日期、状态栏时间，同样会扫出一整条色块。
    // 真机实测（微信浅色截图、384 宽分析图）：
    //   * 气泡行：色块把文字框包住，左右各留 0.030 上下，完全对称，纵向厚度是行高的 2 倍以上；
    //   * 居中日期：色块只有文字笔画那么宽，厚度就是字高（比值 1.0 上下）；
    //   * 导航栏那种带渐变的大色块：文字偏在一侧，左右留白 0.026 / 0.444，严重不对称。

    /// 气泡必须在文字左右各留出这么多空白（相对图宽）。
    var minimumBubblePadding: Double = 0.010
    /// 左右留白的不对称下限（较小 / 较大）。气泡是抱着文字的，大片背景色块不是。
    var paddingSymmetryFloor: Double = 0.25
    /// 色块内部被填充的比例下限（裸文字的笔画之间会露出底色）。
    var minimumBubbleFill: Double = 0.85
    /// 色块纵向厚度 / 文字框高度 的下限（气泡上下有填充，裸文字没有）。
    var bubbleThicknessFactor: Double = 1.5

    static let standard = ChatBubbleScanConfig()
}

// MARK: - 扫描

enum ChatBubbleScanner {

    /// 估画布底色：把像素按 4 bit/通道量化后取众数，再用落在这个桶里的像素求平均。
    ///
    /// 聊天截图的底色永远占大头（真机那张占 62%），所以众数稳。
    /// 估不出来（空图）时返回 nil，调用方就退回老口径，不会瞎判。
    static func background(
        of rows: ChatPixelRows,
        config: ChatBubbleScanConfig = .standard
    ) -> ChatRGB? {
        guard !rows.pixels.isEmpty else { return nil }
        let bits = max(1, min(6, config.backgroundQuantizationBits))
        let levels = 1 << bits
        var buckets: [Int: (count: Int, red: Double, green: Double, blue: Double)] = [:]
        var index = 0
        while index < rows.pixels.count {
            let pixel = rows.pixels[index]
            let redBucket = bucketIndex(pixel.red, levels: levels)
            let greenBucket = bucketIndex(pixel.green, levels: levels)
            let blueBucket = bucketIndex(pixel.blue, levels: levels)
            let key = (redBucket << (2 * bits)) | (greenBucket << bits) | blueBucket
            var entry = buckets[key] ?? (count: 0, red: 0, green: 0, blue: 0)
            entry.count += 1
            entry.red += pixel.red
            entry.green += pixel.green
            entry.blue += pixel.blue
            buckets[key] = entry
            index += 7
        }
        var bestKey: Int?
        var bestCount = 0
        for (key, entry) in buckets where entry.count > bestCount {
            bestCount = entry.count
            bestKey = key
        }
        guard let foundKey = bestKey, bestCount > 0, let best = buckets[foundKey] else {
            return nil
        }
        let divisor = Double(best.count)
        return ChatRGB(
            red: best.red / divisor,
            green: best.green / divisor,
            blue: best.blue / divisor
        )
    }

    /// 一行的横向色块（不做并集，纯粹给测试和小规模用途）。
    static func spans(
        inRow row: [ChatRGB],
        background: ChatRGB,
        config: ChatBubbleScanConfig = .standard
    ) -> [ChatBubbleSpan] {
        guard !row.isEmpty else { return [] }
        var marked = [Bool](repeating: false, count: row.count)
        var markedGreenish = [Bool](repeating: false, count: row.count)
        for (offset, pixel) in row.enumerated() {
            guard pixel.distance(to: background) > config.tolerance else { continue }
            marked[offset] = true
            markedGreenish[offset] = pixel.isGreenish
        }
        return spans(
            fromColumns: marked,
            greenishColumns: markedGreenish,
            gapTolerance: config.gapTolerance,
            minimumSpanWidth: config.minimumSpanWidth,
            edgeSlack: config.edgeSlack
        )
    }

    /// 一行文字所在气泡的证据。扫不出来就返回 nil（调用方退回老口径）。
    static func evidence(
        forText box: ChatLayoutBox,
        rows: ChatPixelRows,
        background: ChatRGB,
        config: ChatBubbleScanConfig = .standard
    ) -> ChatBubbleEvidence? {
        guard rows.width >= 4, rows.height >= 1 else { return nil }

        let sampleIndexes = sampleRowIndexes(for: box, height: rows.height, count: config.rowSampleCount)
        guard !sampleIndexes.isEmpty else { return nil }

        // 多行取并集：Vision 的文字框会横穿笔画，单行扫描会在笔画之间断开，
        // 并集能把「气泡内部有字」的洞补上，又不改变气泡的左右边界。
        var columns = [Bool](repeating: false, count: rows.width)
        var columnsGreenish = [Bool](repeating: false, count: rows.width)
        for rowIndex in sampleIndexes {
            let row = rows.row(atIndex: rowIndex)
            for offset in 0..<row.count {
                let pixel = row[offset]
                guard pixel.distance(to: background) > config.tolerance else { continue }
                columns[offset] = true
                if pixel.isGreenish {
                    columnsGreenish[offset] = true
                }
            }
        }

        let allSpans = spans(
            fromColumns: columns,
            greenishColumns: columnsGreenish,
            gapTolerance: config.gapTolerance,
            minimumSpanWidth: config.minimumSpanWidth,
            edgeSlack: config.edgeSlack
        )
        guard !allSpans.isEmpty else { return nil }

        // 选中「包含文字中心」的那一块；没有就选横向重叠最大的。
        let center = box.centerX
        var chosenIndex = -1
        for (offset, span) in allSpans.enumerated() where span.minX <= center && center <= span.maxX {
            chosenIndex = offset
            break
        }
        if chosenIndex < 0 {
            var bestOverlap = -1.0
            for (offset, span) in allSpans.enumerated() {
                let overlap = min(span.maxX, box.maxX) - max(span.minX, box.minX)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    chosenIndex = offset
                }
            }
        }
        guard chosenIndex >= 0, chosenIndex < allSpans.count else { return nil }
        let bubble = allSpans[chosenIndex]

        // 扫出来的可能只是「文字本身的墨迹」，不是气泡。过不了这一关就当没有气泡证据，
        // 让调用方退回老口径 —— 宁可标「未确定」，也不要把居中日期当成一条聊天气泡。
        guard isBubbleLike(
            bubble,
            textBox: box,
            columns: columns,
            rows: rows,
            background: background,
            sampleIndexes: sampleIndexes,
            config: config
        ) else {
            return nil
        }

        // 头像：同一批采样行里，气泡左右两侧如果还有宽度像头像的独立色块，就记下来。
        var hasLeftAvatar = false
        var hasRightAvatar = false
        for (offset, span) in allSpans.enumerated() where offset != chosenIndex {
            guard config.avatarWidthRange.contains(span.width) else { continue }
            if span.maxX <= bubble.minX {
                hasLeftAvatar = true
            } else if span.minX >= bubble.maxX {
                hasRightAvatar = true
            }
        }
        let avatarSide: ChatAvatarSide
        if hasLeftAvatar && !hasRightAvatar {
            avatarSide = .left
        } else if hasRightAvatar && !hasLeftAvatar {
            avatarSide = .right
        } else {
            avatarSide = .none
        }

        return ChatBubbleEvidence(span: bubble, avatarSide: avatarSide)
    }

    // MARK: 内部

    /// 这条色块是不是「一个装着文字的气泡」，而不是「一段裸文字」。
    private static func isBubbleLike(
        _ span: ChatBubbleSpan,
        textBox box: ChatLayoutBox,
        columns: [Bool],
        rows: ChatPixelRows,
        background: ChatRGB,
        sampleIndexes: [Int],
        config: ChatBubbleScanConfig
    ) -> Bool {
        // 1. 色块要把文字框包在里面，左右各留出一点空白。
        let leftPadding = box.minX - span.minX
        let rightPadding = span.maxX - box.maxX
        guard leftPadding >= config.minimumBubblePadding,
              rightPadding >= config.minimumBubblePadding else {
            return false
        }
        let wider = max(leftPadding, rightPadding)
        let narrower = min(leftPadding, rightPadding)
        guard wider <= 0 || narrower / wider >= config.paddingSymmetryFloor else {
            return false
        }

        // 2. 色块内部基本被填满（裸文字的笔画之间会露出底色）。
        let from = max(0, min(columns.count - 1, Int((span.minX * Double(rows.width)).rounded(.down))))
        let rawTo = Int((span.maxX * Double(rows.width)).rounded(.up)) - 1
        let to = max(0, min(columns.count - 1, rawTo))
        guard from <= to else { return false }
        var marked = 0
        for offset in from...to where columns[offset] {
            marked += 1
        }
        let fill = Double(marked) / Double(to - from + 1)
        guard fill >= config.minimumBubbleFill else { return false }

        // 3. 纵向厚度要明显大于这一行文字的高度（气泡上下还有填充）。
        //
        // 取值列要**靠色块两端**：那里是气泡的内边距，没有字，量到的就是气泡的真实厚度。
        // 取中间几列会被文字抗锯齿坑到 —— 浅色主题里「深色字 -> 白色气泡」的过渡一定会
        // 经过画布那档灰度，于是纵向连续被切断，量出来的厚度等于字高，真气泡会被误杀。
        var thickness = 0.0
        for fraction in [0.04, 0.10, 0.90, 0.96, 0.5] {
            let column = min(
                rows.width - 1,
                max(0, Int(((span.minX + span.width * fraction) * Double(rows.width)).rounded(.down)))
            )
            thickness = max(
                thickness,
                verticalThickness(
                    atColumn: column,
                    sampleIndexes: sampleIndexes,
                    rows: rows,
                    background: background,
                    tolerance: config.tolerance
                )
            )
        }
        guard thickness >= box.height * config.bubbleThicknessFactor else { return false }
        return true
    }

    /// 某一列上，「不是底色」的连续纵向长度（相对图高）。
    private static func verticalThickness(
        atColumn column: Int,
        sampleIndexes: [Int],
        rows: ChatPixelRows,
        background: ChatRGB,
        tolerance: Double
    ) -> Double {
        guard rows.width >= 1, rows.height >= 1, column >= 0, column < rows.width else { return 0 }
        func isMarked(_ row: Int) -> Bool {
            guard row >= 0, row < rows.height else { return false }
            return rows.pixels[row * rows.width + column].distance(to: background) > tolerance
        }
        // 允许中间漏一行：抗锯齿、JPEG 压缩都会让零星一行正好落回底色附近，
        // 不允许漏行的话，一个完整气泡会被这一行切断，量出来只有字那么高。
        func extent(from start: Int, step: Int) -> Int {
            var cursor = start
            var lastMarked = start
            var misses = 0
            while true {
                let next = cursor + step
                guard next >= 0, next < rows.height else { break }
                cursor = next
                if isMarked(cursor) {
                    lastMarked = cursor
                    misses = 0
                } else {
                    misses += 1
                    if misses > 1 { break }
                }
            }
            return lastMarked
        }
        var thickness = 0.0
        for start in sampleIndexes where isMarked(start) {
            let top = extent(from: start, step: -1)
            let bottom = extent(from: start, step: 1)
            thickness = max(thickness, Double(bottom - top + 1) / Double(rows.height))
        }
        return thickness
    }

    private static func bucketIndex(_ value: Double, levels: Int) -> Int {
        let scaled = Int((min(max(value, 0), 1) * Double(levels)).rounded(.down))
        return min(levels - 1, max(0, scaled))
    }

    /// 一行文字在采样图里的哪几行。文字框很薄时只取中间一行，避免采到气泡外面。
    private static func sampleRowIndexes(for box: ChatLayoutBox, height: Int, count: Int) -> [Int] {
        guard height >= 1 else { return [] }
        let samples = max(1, min(count, height))
        let top = box.minY * Double(height - 1)
        let bottom = box.maxY * Double(height - 1)
        if bottom - top < 1 {
            return [min(height - 1, max(0, Int(((top + bottom) / 2).rounded())))]
        }
        var indexes: [Int] = []
        for step in 0..<samples {
            let fraction = samples == 1 ? 0.5 : Double(step) / Double(samples - 1)
            let value = top + (bottom - top) * fraction
            let index = min(height - 1, max(0, Int(value.rounded())))
            if indexes.last != index {
                indexes.append(index)
            }
        }
        return indexes
    }

    /// 把「哪些列不是底色」切成色块。相邻色块之间的小缝隙（文字笔画）会补上。
    private static func spans(
        fromColumns columns: [Bool],
        greenishColumns: [Bool],
        gapTolerance: Double,
        minimumSpanWidth: Double,
        edgeSlack: Double
    ) -> [ChatBubbleSpan] {
        guard !columns.isEmpty else { return [] }
        let width = Double(columns.count)

        var raw: [(Int, Int)] = []
        var start: Int?
        for offset in 0..<columns.count {
            if columns[offset] {
                if start == nil {
                    start = offset
                }
            } else if let existing = start {
                raw.append((existing, offset - 1))
                start = nil
            }
        }
        if let existing = start {
            raw.append((existing, columns.count - 1))
        }
        guard !raw.isEmpty else { return [] }

        var merged: [(Int, Int)] = []
        for run in raw {
            if let last = merged.last, Double(max(run.0 - last.1 - 1, 0)) / width <= gapTolerance {
                merged[merged.count - 1] = (last.0, run.1)
            } else {
                merged.append(run)
            }
        }

        var result: [ChatBubbleSpan] = []
        for run in merged {
            let minX = Double(run.0) / width
            let maxX = Double(run.1 + 1) / width
            guard maxX - minX >= minimumSpanWidth else { continue }

            var markedCount = 0
            var greenishCount = 0
            for offset in run.0...run.1 where columns[offset] {
                markedCount += 1
                if offset < greenishColumns.count && greenishColumns[offset] {
                    greenishCount += 1
                }
            }
            let isGreen = markedCount > 0
                && Double(greenishCount) / Double(markedCount) >= 0.5
            result.append(
                ChatBubbleSpan(
                    minX: minX,
                    maxX: maxX,
                    tone: isGreen ? .greenish : .neutral,
                    touchesImageLeftEdge: minX <= edgeSlack,
                    touchesImageRightEdge: maxX >= 1 - edgeSlack
                )
            )
        }
        return result
    }
}
