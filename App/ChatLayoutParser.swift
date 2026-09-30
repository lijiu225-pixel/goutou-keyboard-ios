import Foundation

// MARK: - 几何
//
// 不用 CGRect / CGFloat，是为了这个文件只依赖 Foundation：
// CI 上可以直接 `swiftc App/ChatLayoutParser.swift` 单独编译并跑冒烟测试，
// 不需要模拟器，也不需要 Vision / UIKit。
//
// 坐标口径在整个流程里只有一种：**归一化、左上角为原点**（和 Vision 的 bottom-left 相反，
// 转换在 `ChatOCRService` 里做）。

struct ChatLayoutBox: Equatable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.init(minX: x, minY: y, maxX: x + width, maxY: y + height)
    }

    var width: Double { max(0, maxX - minX) }
    var height: Double { max(0, maxY - minY) }
    var centerX: Double { (minX + maxX) / 2 }

    /// 两个框的纵向重叠长度。
    func verticalOverlap(with other: ChatLayoutBox) -> Double {
        max(0, min(maxY, other.maxY) - max(minY, other.minY))
    }

    /// 两个框的横向重叠长度。
    func horizontalOverlap(with other: ChatLayoutBox) -> Double {
        max(0, min(maxX, other.maxX) - max(minX, other.minX))
    }

    func union(_ other: ChatLayoutBox) -> ChatLayoutBox {
        ChatLayoutBox(
            minX: min(minX, other.minX),
            minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX),
            maxY: max(maxY, other.maxY)
        )
    }
}

// MARK: - 输入 / 输出模型

/// OCR 出来的一行。`ChatOCRService` 负责产出它，`ChatLayoutParser` 负责整理它。
struct ChatOCRLine: Equatable {
    let text: String
    let box: ChatLayoutBox
    let confidence: Float

    init(text: String, box: ChatLayoutBox, confidence: Float) {
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

/// 一条聊天消息的归属。
///
/// `unknown` 是**一等公民**：版式看不出来时不猜，直接标「未确定」，由用户在 App 里定。
enum ChatLayoutRole: String, Codable, CaseIterable {
    case me
    case other
    case unknown

    var displayName: String {
        switch self {
        case .me: return "我"
        case .other: return "对方"
        case .unknown: return "未确定"
        }
    }

    /// 只有定下来的才能写进剪贴板；`unknown` 返回 nil，编码前会被拦下来。
    var clipboardRole: GoutouChatRole? {
        switch self {
        case .me: return .me
        case .other: return .other
        case .unknown: return nil
        }
    }

    /// 界面上给用户选的顺序。
    static let selectable: [ChatLayoutRole] = [.me, .other, .unknown]
}

/// 整理之后的一条消息。`text` 和 `role` 都是可改的（用户在 App 里修正）。
struct ChatLayoutMessage: Equatable, Identifiable {
    let id: UUID
    var role: ChatLayoutRole
    var text: String
    let box: ChatLayoutBox
    /// 这一条里最低的那行置信度，用来提示「这行可能识别错了」。
    let confidence: Float

    init(
        id: UUID = UUID(),
        role: ChatLayoutRole,
        text: String,
        box: ChatLayoutBox,
        confidence: Float
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.box = box
        self.confidence = confidence
    }

    var needsReview: Bool { role == .unknown }
}

// MARK: - 阈值（全部集中在这里）

/// 版式判定的全部魔数。真机上调参只改这一处。
///
/// 量纲说明：所有 *Ratio 都是**相对内容区宽度**的比例，*Factor 是**相对行高中位数**的倍数，
/// 所以整套阈值和图片分辨率、和缩放比例无关。
struct ChatLayoutThresholds {
    /// 内容区宽度小于这个值就不做角色判断（全是零散文字，判了也是错的）。
    var minAreaWidth: Double = 0.20
    /// 两行纵向重叠 / 行高 ≥ 该值 → 算同一视觉行，同一行里按左到右排。
    var rowOverlapRatio: Double = 0.35
    /// 同一气泡内相邻行的最大纵向间距 = 行高中位数 × 该值。
    /// 调大 → 一个气泡更容易被并成一条；调小 → 一句话可能被拆成两条。
    var maxLineGapFactor: Double = 0.60
    /// 并进同一气泡要求的横向重叠 / 较短者宽度。
    var minHorizontalOverlap: Double = 0.55
    /// 到某一侧的间隙 ≤ 内容区宽 × 该值 → 认为贴这一侧。
    var nearGapRatio: Double = 0.06
    /// 贴边判定的补充条件：到对侧间隙 ≥ 内容区宽 × 该值。
    var farGapRatio: Double = 0.18
    /// 一般判定要求的最小倾向分 |leftRatio - rightRatio|。
    var judgeMargin: Double = 0.12
    /// 气泡宽 / 内容区宽 ≥ 该值 → 视为整屏宽，判定更保守。
    var fullWidthRatio: Double = 0.82
    /// 整屏宽气泡要求的最小倾向分（比 judgeMargin 高）。
    var fullWidthMargin: Double = 0.30
    /// 两侧间隙都大于该值 → 居中悬浮的通知类文字，判不了。
    var ambiguousGapRatio: Double = 0.12
    /// 低于该置信度的行直接丢。默认 0 —— 宁可让用户自己删，也不要静默吞掉内容。
    var minConfidence: Float = 0

    static let `default` = ChatLayoutThresholds()
}

// MARK: - 解析器

/// 把 OCR 的散行整理成「按阅读顺序排列、每条带归属」的聊天记录。
///
/// 判定口径（**不是** `midX < 0.5`）：
/// 1. 先按上→下、同一视觉行内左→右排成阅读顺序；
/// 2. 纵向够近且横向有重叠的相邻行并成同一个气泡（多行气泡是一条消息，不是几条）；
/// 3. 拿所有气泡的外接矩形当「内容区」，每条气泡看**到左右边缘的间隙**、
///    自身**宽度占比**，算出一个倾向分 `leftRatio - rightRatio`（>0 偏右 = 自己）；
/// 4. 贴边、整屏宽、居中悬浮各有专门规则；说不出所以然的一律 `.unknown`。
///
/// 已知取舍：同一侧、间距极小的两条独立消息可能被并成一条（`maxLineGapFactor` 控制）。
/// 宁可少量合并，也不要把一个多行气泡切成好几条——用户改归属比重新拼接文本省事。
enum ChatLayoutParser {

    static func parse(
        lines: [ChatOCRLine],
        thresholds: ChatLayoutThresholds = .default
    ) -> [ChatLayoutMessage] {
        let kept = lines.filter {
            !layoutTrimmed($0.text).isEmpty && $0.confidence >= thresholds.minConfidence
        }
        guard !kept.isEmpty else { return [] }

        let ordered = readingOrder(kept, thresholds: thresholds)
        let blocks = cluster(ordered, thresholds: thresholds)

        // 内容区 = 所有气泡的外接矩形。它同时近似了聊天内容的左右边距。
        var area = blocks[0].box
        for block in blocks.dropFirst() {
            area = area.union(block.box)
        }
        guard area.width >= thresholds.minAreaWidth else {
            // 内容太窄（例如只有一行短文字），左右没有可比性。
            return blocks.map { makeMessage($0, role: .unknown) }
        }

        return blocks.map { block in
            makeMessage(block, role: role(for: block.box, area: area, thresholds: thresholds))
        }
    }

    // MARK: 1. 阅读顺序

    /// 先按 y 排，再把纵向重叠的行归成「视觉行」，行内按 x 排。
    /// 刻意不用带交叉条件的 `sorted(by:)`——那种比较器不满足严格弱序，排序结果不稳定。
    private static func readingOrder(
        _ lines: [ChatOCRLine],
        thresholds: ChatLayoutThresholds
    ) -> [ChatOCRLine] {
        let byTop = lines.enumerated().sorted { lhs, rhs in
            if lhs.element.box.minY != rhs.element.box.minY {
                return lhs.element.box.minY < rhs.element.box.minY
            }
            // 同 y 用原始下标兜底，保证排序完全确定。
            return lhs.offset < rhs.offset
        }.map { $0.element }

        var rows: [[ChatOCRLine]] = []
        /// 参考带只用**这一行的第一行**，不随加入的行扩大——
        /// 一路 union 下去会把整张长图串成「一行」，阅读顺序就全乱了。
        var rowBand: ChatLayoutBox?
        for line in byTop {
            if let band = rowBand,
               band.verticalOverlap(with: line.box) >= min(band.height, line.box.height) * thresholds.rowOverlapRatio {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
                rowBand = line.box
            }
        }

        return rows.flatMap { row in
            row.enumerated().sorted { lhs, rhs in
                if lhs.element.box.minX != rhs.element.box.minX {
                    return lhs.element.box.minX < rhs.element.box.minX
                }
                return lhs.offset < rhs.offset
            }.map { $0.element }
        }
    }

    // MARK: 2. 并气泡

    private struct Block {
        var lines: [ChatOCRLine]
        var box: ChatLayoutBox
    }

    private static func cluster(
        _ ordered: [ChatOCRLine],
        thresholds: ChatLayoutThresholds
    ) -> [Block] {
        let medianHeight = median(of: ordered.map { $0.box.height })
        let maxGap = max(medianHeight, 0.0001) * thresholds.maxLineGapFactor

        var blocks: [Block] = []
        for line in ordered {
            if var last = blocks.last, canAttach(line, to: last, maxGap: maxGap, thresholds: thresholds) {
                last.lines.append(line)
                last.box = last.box.union(line.box)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(Block(lines: [line], box: line.box))
            }
        }
        return blocks
    }

    private static func canAttach(
        _ line: ChatOCRLine,
        to block: Block,
        maxGap: Double,
        thresholds: ChatLayoutThresholds
    ) -> Bool {
        // 纵向：不能离太远；也不能跑到上一个气泡上面去。
        let gap = line.box.minY - block.box.maxY
        guard gap <= maxGap, line.box.maxY > block.box.minY else { return false }

        // 横向：必须和已有内容重叠。同高的左右两条消息就是靠这一步分开的。
        let shorter = max(min(line.box.width, block.box.width), 0.0001)
        let overlap = line.box.horizontalOverlap(with: block.box) / shorter
        return overlap >= thresholds.minHorizontalOverlap
    }

    // MARK: 3. 判角色

    private static func role(
        for box: ChatLayoutBox,
        area: ChatLayoutBox,
        thresholds: ChatLayoutThresholds
    ) -> ChatLayoutRole {
        let width = area.width
        let leftRatio = (box.minX - area.minX) / width
        let rightRatio = (area.maxX - box.maxX) / width
        let widthRatio = box.width / width
        // 偏右为正。这一项同时揉进了「左右边缘间隙」和「中心位置」，
        // 但它是判定的**依据之一**，不是唯一依据。
        let score = leftRatio - rightRatio

        // 两边都不贴 → 居中悬浮（撤回提示、系统通知这类），不猜。
        if leftRatio > thresholds.ambiguousGapRatio && rightRatio > thresholds.ambiguousGapRatio {
            return .unknown
        }

        if widthRatio >= thresholds.fullWidthRatio {
            // 几乎占满整屏：左右都贴边，得看更大的倾向分才敢下结论。
            if score >= thresholds.fullWidthMargin { return .me }
            if score <= -thresholds.fullWidthMargin { return .other }
            return .unknown
        }

        // 贴边规则：贴左且离右够远 → 对方；贴右且离左够远 → 我。
        if leftRatio <= thresholds.nearGapRatio && rightRatio >= thresholds.farGapRatio {
            return .other
        }
        if rightRatio <= thresholds.nearGapRatio && leftRatio >= thresholds.farGapRatio {
            return .me
        }

        if score >= thresholds.judgeMargin { return .me }
        if score <= -thresholds.judgeMargin { return .other }
        return .unknown
    }

    // MARK: 汇总

    private static func makeMessage(_ block: Block, role: ChatLayoutRole) -> ChatLayoutMessage {
        ChatLayoutMessage(
            role: role,
            // 用换行拼：Vision 是按「文本行」给结果的，
            // 具体是同一句被折行还是两句独立的话，人一眼就能改。
            text: block.lines.map { layoutTrimmed($0.text) }.joined(separator: "\n"),
            box: block.box,
            confidence: block.lines.map { $0.confidence }.min() ?? 0
        )
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// 自带一份 trim，不用 `GoutouConfig.swift` 里那份 `String.trimmed`：
/// 那个文件不在 `tools/ChatLayoutCheck` 的独立编译范围里，自己带着才能单飞。
private func layoutTrimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}
