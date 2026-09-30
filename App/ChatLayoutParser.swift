import Foundation

// MARK: - 几何
//
// 不用 CGRect / CGFloat，是为了这个文件只依赖 Foundation：
// CI 上可以直接 swiftc App/ChatLayoutParser.swift 单独编译并跑冒烟测试，
// 不需要模拟器，也不需要 Vision / UIKit。
//
// 坐标口径在整个流程里只有一种：**归一化、左上角为原点**（和 Vision 的 bottom-left 相反，
// 转换在 ChatOCRService 里做）。

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
    var centerY: Double { (minY + maxY) / 2 }

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

/// OCR 出来的一行。ChatOCRService 负责产出它，ChatLayoutParser 负责整理它。
struct ChatOCRLine: Equatable {
    let text: String
    let box: ChatLayoutBox
    let confidence: Float
    /// 这一行**所在气泡**的扫描证据（见 GoutouChatBubbleScanner.swift）。
    ///
    /// nil 有两个来源：老路径 / 纯逻辑测试（没有像素可扫），或者扫描没找到气泡。
    /// 这时角色判定会退回「文字框贴边」的老口径，宁可标「未确定」也不硬猜。
    let bubble: ChatBubbleEvidence?

    init(
        text: String,
        box: ChatLayoutBox,
        confidence: Float,
        bubble: ChatBubbleEvidence? = nil
    ) {
        self.text = text
        self.box = box
        self.confidence = confidence
        self.bubble = bubble
    }
}

/// 一条聊天消息的归属。
///
/// unknown 是**一等公民**：版式看不出来时不猜，直接标「未确定」，由用户在 App 里定。
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

    /// 只有定下来的才能写进剪贴板；unknown 返回 nil，编码前会被拦下来。
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

/// 被判成「不是聊天」的原因。要能直接给人看。
enum ChatNonChatReason: String, Equatable {
    /// 顶部：状态栏时间、电量、聊天标题、返回/更多按钮。
    case header
    /// 底部：输入框、工具条。
    case footer
    /// 底部：可见键盘的按键。
    case keyboard
    /// 居中的日期时间分隔（9月21日 21:56 这类）。
    case dateSeparator
    /// 居中的系统提示（撤回、拍一拍、朋友验证）。
    case systemNotice
    /// 通话记录（已取消 / 通话时长 00:12）。
    case callRecord

    var displayName: String {
        switch self {
        case .header: return "顶部状态栏/标题"
        case .footer: return "底部输入区"
        case .keyboard: return "键盘"
        case .dateSeparator: return "日期时间"
        case .systemNotice: return "系统提示"
        case .callRecord: return "通话记录"
        }
    }
}

/// 一条结果在「是不是聊天」上的定性。
enum ChatLayoutKind: Equatable {
    /// 正常聊天消息。
    case chat
    /// 疑似系统内容（居中日期、撤回提示、通话记录）。
    ///
    /// 进列表但**默认不复制**：版式上说得通，但同一个词也可能是真实聊天内容
    /// （比如有人真的发了「已取消」），所以交给用户一键放回，而不是直接删掉。
    case nonChatCandidate(ChatNonChatReason)

    var reason: ChatNonChatReason? {
        switch self {
        case .chat: return nil
        case .nonChatCandidate(let reason): return reason
        }
    }

    var isChat: Bool { self == .chat }

    var isCandidate: Bool {
        if case .nonChatCandidate = self { return true }
        return false
    }
}

/// 整理之后的一条消息。text / role / isKept 都是可改的（用户在 App 里修正）。
struct ChatLayoutMessage: Equatable, Identifiable {
    let id: UUID
    var role: ChatLayoutRole
    var text: String
    let box: ChatLayoutBox
    /// 这一条里最低的那行置信度，用来提示「这行可能识别错了」。
    let confidence: Float
    /// 聊天消息 / 非聊天候选。
    let kind: ChatLayoutKind
    /// 这一条所在气泡的横向范围（扫描得到才有）。
    let bubble: ChatBubbleSpan?
    /// 复制时是否带上这一条。聊天默认带、非聊天候选默认不带。
    var isKept: Bool
    /// 疑似表情乱码时给出的「去掉末尾杂字」建议文本。nil = 没看出来。
    let suggestedText: String?

    init(
        id: UUID = UUID(),
        role: ChatLayoutRole,
        text: String,
        box: ChatLayoutBox,
        confidence: Float,
        kind: ChatLayoutKind = .chat,
        bubble: ChatBubbleSpan? = nil,
        isKept: Bool? = nil,
        suggestedText: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.box = box
        self.confidence = confidence
        self.kind = kind
        self.bubble = bubble
        self.isKept = isKept ?? kind.isChat
        self.suggestedText = suggestedText
    }

    var needsReview: Bool { role == .unknown }

    /// 建议文本和当前文本一样就没必要提示。
    var hasSuggestedText: Bool {
        guard let suggestedText = suggestedText else { return false }
        return suggestedText != text
    }
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

    // MARK: 第二阶段新增：气泡轨道

    /// 一条「对齐轨道」至少要有这么多条气泡撑着才算成立。
    /// 只有一条气泡贴左、别的都不贴，那不算轨道，也不能拿它反推别人。
    var minRailSupport: Int = 2
    /// 左右轨道的间距小于这个值就不做轨道判定（内容太挤，没有可比性）。
    var minRailSpan: Double = 0.12
    /// 气泡边缘离轨道不超过「轨道间距 × 该值」就算贴在这条轨道上。
    var railTolerance: Double = 0.08
    /// 两条轨道都贴上时，两侧间距差小于「轨道间距 × 该值」就算「贴得一样近」。
    var railTieMargin: Double = 0.02
    /// 判「居中」要求到内容区两侧至少各留这个比例的空档。
    var centeredGapRatio: Double = 0.15
    /// 顶部/底部区域的判定余量（相对内容区高度）。
    var bandSlackRatio: Double = 0.004
    /// 键盘网格：一行至少几条、每条宽度上限。
    var keyboardRowMinimumBlocks: Int = 5
    var keyboardBlockMaxWidth: Double = 0.16
    /// 置信度低于这个值的行才考虑「末尾杂字 = 表情被认错」。
    var symbolNoiseConfidence: Float = 0.5
    /// 给「去掉末尾杂字」建议要求正文至少有多少个汉字。
    /// 取 2 时「我选 C」这种真实短句会被误判，所以收到 3。
    var symbolNoiseMinimumCJK: Int = 3

    static let `default` = ChatLayoutThresholds()
}

/// 被排除掉的内容按原因汇总（只报个数，不回显文字）。
struct ChatLayoutExcludedCount: Equatable {
    let reason: ChatNonChatReason
    let count: Int
}

/// 一次版式分析的全部结果。
struct ChatLayoutResult: Equatable {
    /// 聊天消息 + 非聊天候选（顶部状态栏/底部输入区/键盘这些**确定不是聊天**的已经剔掉了）。
    let messages: [ChatLayoutMessage]
    /// 被剔掉的内容按原因汇总。
    let excludedCounts: [ChatLayoutExcludedCount]

    var excludedTotal: Int {
        excludedCounts.reduce(0) { $0 + $1.count }
    }
}

// MARK: - 解析器

/// 从气泡边缘算出来的两条「对齐轨道」。
private struct ChatBubbleRails: Equatable {
    let left: Double
    let right: Double
    let span: Double
    let leftValid: Bool
    let rightValid: Bool
}

/// 把 OCR 的散行整理成「按阅读顺序排列、每条带归属」的聊天记录。
///
/// 判定口径（**不是** midX < 0.5）：
/// 1. 先按上→下、同一视觉行内左→右排成阅读顺序；
/// 2. 纵向够近且横向有重叠的相邻行并成同一个气泡（多行气泡是一条消息，不是几条）；
/// 3. 有气泡扫描结果时：拿所有气泡的**左右边缘**找两条对齐轨道
///    （右侧消息共用一条右边缘、左侧消息共用一条左边缘），贴在哪条轨道上就是哪一侧；
///    实在判不出来才看头像，最后才考虑气泡颜色；
/// 4. 没有气泡扫描结果时（纯逻辑测试、扫描失败）：退回上一阶段的文字框贴边口径，
///    说不出所以然的一律 unknown；
/// 5. 顶部状态栏/标题、底部输入区/键盘按内容区上下边界剔掉；
///    居中的日期时间、系统提示、通话记录只标成「非聊天候选」，默认不复制，用户可放回。
enum ChatLayoutParser {

    /// 只要消息数组的旧入口（测试和老调用点用）。
    static func parse(
        lines: [ChatOCRLine],
        thresholds: ChatLayoutThresholds = .default
    ) -> [ChatLayoutMessage] {
        analyze(lines: lines, thresholds: thresholds).messages
    }

    /// 完整入口：消息 + 被剔掉内容的汇总。
    static func analyze(
        lines: [ChatOCRLine],
        thresholds: ChatLayoutThresholds = .default
    ) -> ChatLayoutResult {
        let kept = lines.filter {
            !layoutTrimmed($0.text).isEmpty && $0.confidence >= thresholds.minConfidence
        }
        guard !kept.isEmpty else {
            return ChatLayoutResult(messages: [], excludedCounts: [])
        }

        let ordered = readingOrder(kept, thresholds: thresholds)
        let blocks = cluster(ordered, thresholds: thresholds)

        // 内容区 = 所有块的外接矩形（没气泡时兜底用；有气泡时下面会换成气泡范围）。
        var area = blocks[0].box
        for block in blocks.dropFirst() {
            area = area.union(block.box)
        }

        // 键盘按键会伪装成小气泡，先认出来，别让它参与轨道和上下边界的计算。
        let keyboardIndexes = keyboardBlockIndexes(blocks, thresholds: thresholds)
        let evidencedIndexes = blocks.indices.filter {
            !keyboardIndexes.contains($0) && blocks[$0].bubble != nil
        }
        let rails = bubbleRails(
            spans: evidencedIndexes.compactMap { blocks[$0].bubble },
            thresholds: thresholds
        )

        // 聊天内容区（上下边界）和左右内容边界都优先用气泡，而不是文字框。
        var bandTop: Double?
        var bandBottom: Double?
        var contentLeft = area.minX
        var contentRight = area.maxX
        for index in evidencedIndexes {
            let box = blocks[index].box
            bandTop = bandTop.map { min($0, box.minY) } ?? box.minY
            bandBottom = bandBottom.map { max($0, box.maxY) } ?? box.maxY
            if let bubble = blocks[index].bubble {
                contentLeft = min(contentLeft, bubble.minX)
                contentRight = max(contentRight, bubble.maxX)
            }
        }
        let bandHeight = (bandBottom ?? 0) - (bandTop ?? 0)
        let bandSlack = max(bandHeight, 0) * thresholds.bandSlackRatio

        var messages: [ChatLayoutMessage] = []
        var excludedCounts: [ChatNonChatReason: Int] = [:]

        for index in blocks.indices {
            let block = blocks[index]
            let text = blockText(block)
            let hasBubble = block.bubble != nil

            if keyboardIndexes.contains(index) {
                excludedCounts[.keyboard, default: 0] += 1
                continue
            }
            if let top = bandTop, let bottom = bandBottom {
                if block.box.maxY <= top + bandSlack {
                    excludedCounts[.header, default: 0] += 1
                    continue
                }
                if block.box.minY >= bottom - bandSlack {
                    excludedCounts[.footer, default: 0] += 1
                    continue
                }
            }

            var kind: ChatLayoutKind = .chat
            if !hasBubble && isCentered(
                block.box,
                left: contentLeft,
                right: contentRight,
                thresholds: thresholds
            ) {
                if isDateOrTimeSeparator(text) {
                    kind = .nonChatCandidate(.dateSeparator)
                } else if isSystemNotice(text) {
                    kind = .nonChatCandidate(.systemNotice)
                }
            }
            // 通话记录在微信里也是有气泡的（右侧绿色），所以不能靠「没有气泡」认，
            // 只能靠「整条就是一句通话状态」。认不准的一律只当候选，用户能一键放回。
            if kind.isChat, hasBubble, isCallRecord(text) {
                kind = .nonChatCandidate(.callRecord)
            }

            messages.append(
                makeMessage(
                    block,
                    role: roleFor(block: block, area: area, rails: rails, thresholds: thresholds),
                    kind: kind,
                    thresholds: thresholds
                )
            )
        }

        let reasonOrder: [ChatNonChatReason] = [
            .header, .footer, .keyboard, .dateSeparator, .systemNotice, .callRecord,
        ]
        let summary = reasonOrder.compactMap { reason -> ChatLayoutExcludedCount? in
            guard let count = excludedCounts[reason], count > 0 else { return nil }
            return ChatLayoutExcludedCount(reason: reason, count: count)
        }
        return ChatLayoutResult(messages: messages, excludedCounts: summary)
    }

    // MARK: 1. 阅读顺序

    /// 先按 y 排，再把纵向重叠的行归成「视觉行」，行内按 x 排。
    /// 刻意不用带交叉条件的 sorted(by:)——那种比较器不满足严格弱序，排序结果不稳定。
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
        var bubble: ChatBubbleSpan?
        var avatarSide: ChatAvatarSide
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
                if let span = line.bubble?.span {
                    last.bubble = last.bubble.map { $0.union(span) } ?? span
                }
                if last.avatarSide == .none, let side = line.bubble?.avatarSide, side != .none {
                    last.avatarSide = side
                }
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(
                    Block(
                        lines: [line],
                        box: line.box,
                        bubble: line.bubble?.span,
                        avatarSide: line.bubble?.avatarSide ?? .none
                    )
                )
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

    private static func roleFor(
        block: Block,
        area: ChatLayoutBox,
        rails: ChatBubbleRails?,
        thresholds: ChatLayoutThresholds
    ) -> ChatLayoutRole {
        if let bubble = block.bubble {
            return role(
                forBubble: bubble,
                avatarSide: block.avatarSide,
                rails: rails,
                thresholds: thresholds
            )
        }
        return role(for: block.box, area: area, thresholds: thresholds)
    }

    /// 有气泡证据时的判定：只认**气泡边缘**。
    ///
    /// 为什么不看文字宽度：真机上一句长话的文字框能从气泡左内边一直撑到右内边，
    /// 「文字框贴左」在长句上完全失效。气泡边缘是唯一稳定的东西。
    private static func role(
        forBubble bubble: ChatBubbleSpan,
        avatarSide: ChatAvatarSide,
        rails: ChatBubbleRails?,
        thresholds: ChatLayoutThresholds
    ) -> ChatLayoutRole {
        var leftGap = 0.0
        var rightGap = 0.0
        var leftAnchored = bubble.touchesImageLeftEdge
        var rightAnchored = bubble.touchesImageRightEdge

        if let rails = rails {
            // 用**绝对距离**：气泡比轨道还靠外时（被裁到边缘、或者比最长的那条还长）
            // 单侧差会算成负数，于是「贴着右边」被误判成立。
            leftGap = abs(bubble.minX - rails.left) / rails.span
            rightGap = abs(rails.right - bubble.maxX) / rails.span
            if rails.leftValid && leftGap <= thresholds.railTolerance {
                leftAnchored = true
            }
            if rails.rightValid && rightGap <= thresholds.railTolerance {
                rightAnchored = true
            }
        }

        if leftAnchored && rightAnchored {
            if rightGap + thresholds.railTieMargin < leftGap { return .me }
            if leftGap + thresholds.railTieMargin < rightGap { return .other }
            // 两边贴得一样近：整屏宽的长气泡，颜色只在这种僵局里当辅助。
            return bubble.tone == .greenish ? .me : .unknown
        }
        if rightAnchored { return .me }
        if leftAnchored { return .other }

        // 轨道上都没贴上：只有在头像明确出现在一侧时才下结论。
        switch avatarSide {
        case .right: return .me
        case .left: return .other
        case .none: break
        }
        return .unknown
    }

    /// 没有气泡证据时的老口径：拿文字框相对内容区的左右间隙算倾向分。
    private static func role(
        for box: ChatLayoutBox,
        area: ChatLayoutBox,
        thresholds: ChatLayoutThresholds
    ) -> ChatLayoutRole {
        let width = area.width
        // 内容太窄（例如只有一行短文字），左右没有可比性。
        guard width >= thresholds.minAreaWidth else { return .unknown }

        let leftRatio = (box.minX - area.minX) / width
        let rightRatio = (area.maxX - box.maxX) / width
        let widthRatio = box.width / width
        // 偏右为正。
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

    // MARK: 4. 对齐轨道

    /// 从所有气泡边缘里找出「右侧共用边缘」和「左侧共用边缘」。
    ///
    /// 真机数字：右侧 6 条绿气泡的最大 x 全部落在 0.8646...0.8672（同一根轨道），
    /// 左侧 5 条白气泡的最小 x 全部是 0.1354。轨道成立需要至少 minRailSupport 条撑着，
    /// 否则「只有一条贴边」不构成参照，不能拿它反推别人。
    private static func bubbleRails(
        spans: [ChatBubbleSpan],
        thresholds: ChatLayoutThresholds
    ) -> ChatBubbleRails? {
        // 被截图边缘裁掉的气泡不能用它们的边缘定义轨道（那不是气泡的真边缘）。
        let usable = spans.filter { !$0.touchesImageLeftEdge && !$0.touchesImageRightEdge }
        guard usable.count >= thresholds.minRailSupport else { return nil }

        var left = Double.greatestFiniteMagnitude
        var right = -Double.greatestFiniteMagnitude
        for span in usable {
            left = min(left, span.minX)
            right = max(right, span.maxX)
        }
        let span = right - left
        guard span >= thresholds.minRailSpan else { return nil }

        let tolerance = span * thresholds.railTolerance
        var leftSupport = 0
        var rightSupport = 0
        for item in usable {
            if item.minX - left <= tolerance { leftSupport += 1 }
            if right - item.maxX <= tolerance { rightSupport += 1 }
        }
        return ChatBubbleRails(
            left: left,
            right: right,
            span: span,
            leftValid: leftSupport >= thresholds.minRailSupport,
            rightValid: rightSupport >= thresholds.minRailSupport
        )
    }

    // MARK: 5. 顶部 / 底部 / 键盘

    /// 找出键盘按键所在的行。
    ///
    /// 键盘键帽在像素上和白气泡很像，但版式完全不同：一行里挤着 5 个以上小方块、
    /// 而且这样的行连着两行以上、都在下半屏。真实聊天一行里不可能出现这种排布。
    private static func keyboardBlockIndexes(
        _ blocks: [Block],
        thresholds: ChatLayoutThresholds
    ) -> Set<Int> {
        guard blocks.count >= thresholds.keyboardRowMinimumBlocks * 2 else { return [] }

        let ordered = blocks.indices.sorted { blocks[$0].box.minY < blocks[$1].box.minY }
        var rows: [[Int]] = []
        var rowBand: ChatLayoutBox?
        for index in ordered {
            let box = blocks[index].box
            if let band = rowBand,
               band.verticalOverlap(with: box) >= min(band.height, box.height) * 0.5 {
                rows[rows.count - 1].append(index)
            } else {
                rows.append([index])
                rowBand = box
            }
        }

        var isKeyboard = [Bool](repeating: false, count: blocks.count)
        var runRows = 0
        var runIndexes: [Int] = []
        for row in rows {
            let shortCount = row.filter {
                blocks[$0].box.width <= thresholds.keyboardBlockMaxWidth
            }.count
            let looksLikeKeyboard = shortCount >= thresholds.keyboardRowMinimumBlocks
                && row.allSatisfy { blocks[$0].box.minY >= 0.40 }
            if looksLikeKeyboard {
                runRows += 1
                runIndexes.append(contentsOf: row)
            } else {
                if runRows >= 2 {
                    for index in runIndexes { isKeyboard[index] = true }
                }
                runRows = 0
                runIndexes = []
            }
        }
        if runRows >= 2 {
            for index in runIndexes { isKeyboard[index] = true }
        }
        return Set(blocks.indices.filter { isKeyboard[$0] })
    }

    private static func isCentered(
        _ box: ChatLayoutBox,
        left: Double,
        right: Double,
        thresholds: ChatLayoutThresholds
    ) -> Bool {
        let span = right - left
        guard span >= thresholds.minAreaWidth else { return false }
        let leftGap = (box.minX - left) / span
        let rightGap = (right - box.maxX) / span
        return leftGap >= thresholds.centeredGapRatio && rightGap >= thresholds.centeredGapRatio
    }

    // MARK: 6. 系统内容的文字特征
    //
    // 全部都要配合「居中 + 没有气泡」才生效：单看词太危险
    // （普通聊天里真的会出现「明天21:56」这种）。

    static func isDateOrTimeSeparator(_ text: String) -> Bool {
        let compact = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard !compact.isEmpty, compact.count <= 24 else { return false }

        if compact.contains("月"), compact.contains("日") {
            let parts = compact.components(separatedBy: "日")
            guard parts.count == 2 else { return false }
            var head = parts[0]
            // 「2024年9月21日」：年份必须是四位数字，先剥掉再验月日。
            if let yearMark = head.firstIndex(of: "年") {
                let year = String(head[head.startIndex..<yearMark])
                guard isAllASCIIDigits(year), year.count == 4 else { return false }
                head = String(head[head.index(after: yearMark)...])
            }
            guard let monthMark = head.firstIndex(of: "月") else { return false }
            let month = String(head[head.startIndex..<monthMark])
            let day = String(head[head.index(after: monthMark)...])
            guard isAllASCIIDigits(month), isAllASCIIDigits(day) else { return false }
            let tail = parts[1]
            return tail.isEmpty || looksLikeClock(tail) || isWeekdayWord(tail)
        }
        for prefix in ["昨天", "今天", "前天"] where compact.hasPrefix(prefix) {
            let tail = String(compact.dropFirst(prefix.count))
            return tail.isEmpty || looksLikeClock(tail) || isWeekdayWord(tail)
        }
        if compact.hasPrefix("星期") || compact.hasPrefix("周") {
            return isWeekdayWord(compact)
        }
        for prefix in ["上午", "下午", "凌晨", "中午", "晚上"] where compact.hasPrefix(prefix) {
            return looksLikeClock(String(compact.dropFirst(prefix.count)))
        }
        return looksLikeClock(compact)
    }

    static func isSystemNotice(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        let needles = [
            "撤回了一条消息",
            "拍了拍",
            "以下为新消息",
            "对方正在输入",
            "开启了朋友验证",
            "以上是打招呼的内容",
            "通过你的朋友验证",
        ]
        return needles.contains { compact.contains($0) }
    }

    /// 通话记录：整条就是一句通话状态。
    ///
    /// 只认「整条文字恰好是这些短语之一」或明确以通话时长开头，不做包含匹配——
    /// 否则「他说已取消」这种正常聊天也会被吃掉。
    static func isCallRecord(_ text: String) -> Bool {
        let compact = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "·。.!！?？,，"))
        guard !compact.isEmpty, compact.count <= 10 else { return false }
        let phrases: Set<String> = [
            "已取消", "已拒绝", "已接通", "已结束", "未接听", "未接通", "已挂断",
            "对方已取消", "对方已拒绝", "你已取消", "语音通话", "视频通话", "已取消通话",
        ]
        if phrases.contains(compact) { return true }
        return compact.hasPrefix("通话时长") || compact.hasPrefix("已通话")
    }

    // MARK: 7. 表情乱码

    /// 表情被认成一个孤立的字母/假名时，给出「去掉它」的建议文本。
    ///
    /// 三个条件同时成立才给建议，避免把真实内容改掉：
    /// 1. 这一行的置信度本来就低（Vision 自己也没把握，真机上那两行正是这样）；
    /// 2. 去掉杂字之后正文至少还有 3 个汉字（说明正文是真的，「我选 C」这种短句不会被误伤）；
    /// 3. 首/尾有一个**孤立**的单字符 token，且它不是汉字。
    ///
    /// 而且它只是**建议**：界面上标个提示、由用户点一下才应用，绝不自动改正文。
    static func suggestedTextWithoutSymbolNoise(
        _ text: String,
        confidence: Float,
        thresholds: ChatLayoutThresholds
    ) -> String? {
        guard confidence < thresholds.symbolNoiseConfidence else { return nil }
        let flattened = text.replacingOccurrences(of: "\n", with: " ")

        // 写法一：Vision 在中英之间插了空格，于是末尾多出一个孤立的单字符 token。
        // 例：「他妈的，别让我猜了 C」（表情 😊 被认成 C）
        let tokens = flattened.split(separator: " ").map(String.init)
        if tokens.count >= 2 {
            let edgeIndexes = [tokens.count - 1, 0]
            for edgeIndex in edgeIndexes where edgeIndex >= 0 && edgeIndex < tokens.count {
                guard isNoiseToken(tokens[edgeIndex]) else { continue }
                var remaining = tokens
                remaining.remove(at: edgeIndex)
                let rest = remaining.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                guard !rest.isEmpty, cjkCharacterCount(rest) >= thresholds.symbolNoiseMinimumCJK else { continue }
                return rest
            }
        }

        // 写法二：Vision 没插空格，杂字紧贴在汉字后面。
        // 例：「你平时不这样，我突然听见还有点不习惯こ」（表情 😂 被认成 こ）
        let trimmed = flattened.trimmingCharacters(in: .whitespaces)
        if let dropped = droppingEdgeNoiseCharacter(
            trimmed,
            fromEnd: true,
            minimumCJK: thresholds.symbolNoiseMinimumCJK
        ) {
            return dropped
        }
        if let dropped = droppingEdgeNoiseCharacter(
            trimmed,
            fromEnd: false,
            minimumCJK: thresholds.symbolNoiseMinimumCJK
        ) {
            return dropped
        }
        return nil
    }

    /// 末尾（或开头）紧贴汉字的那一个非汉字字符，去掉它之后正文还够长才给建议。
    private static func droppingEdgeNoiseCharacter(
        _ text: String,
        fromEnd: Bool,
        minimumCJK: Int
    ) -> String? {
        guard text.count >= 2 else { return nil }
        let edgeCharacter: Character = fromEnd ? text[text.index(before: text.endIndex)] : text[text.startIndex]
        guard isNoiseToken(String(edgeCharacter)) else { return nil }
        let remainder = fromEnd ? String(text.dropLast()) : String(text.dropFirst())
        let trimmedRemainder = remainder.trimmingCharacters(in: .whitespaces)
        guard !trimmedRemainder.isEmpty else { return nil }
        let neighbor: Character = fromEnd
            ? trimmedRemainder[trimmedRemainder.index(before: trimmedRemainder.endIndex)]
            : trimmedRemainder[trimmedRemainder.startIndex]
        guard isCJK(neighbor) else { return nil }
        guard cjkCharacterCount(trimmedRemainder) >= minimumCJK else { return nil }
        return trimmedRemainder
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.value >= 0x4E00 && scalar.value <= 0x9FFF
    }

    private static func isNoiseToken(_ token: String) -> Bool {
        guard token.count == 1, let scalar = token.unicodeScalars.first else { return false }
        let value = scalar.value
        if value >= 0x30 && value <= 0x39 { return true }        // 0-9
        if value >= 0x41 && value <= 0x5A { return true }        // A-Z
        if value >= 0x61 && value <= 0x7A { return true }        // a-z
        if value >= 0x3040 && value <= 0x30FF { return true }    // 平假名 / 片假名（表情常被认成这个）
        let symbols: Set<UInt32> = [0x00A9, 0x00AE, 0x2122, 0x2022, 0x00B7, 0x25CB, 0x25CF, 0x2605, 0x2606]
        return symbols.contains(value)
    }

    private static func cjkCharacterCount(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { count += 1 }
        }
        return count
    }

    private static func isAllASCIIDigits(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func looksLikeClock(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return false }
        guard isAllASCIIDigits(parts[0]), parts[0].count <= 2 else { return false }
        for part in parts.dropFirst() {
            guard isAllASCIIDigits(part), part.count == 2 else { return false }
        }
        return true
    }

    private static func isWeekdayWord(_ value: String) -> Bool {
        let names: Set<String> = [
            "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日", "星期天",
            "周一", "周二", "周三", "周四", "周五", "周六", "周日", "周天",
        ]
        return names.contains(value)
    }

    // MARK: 汇总

    private static func blockText(_ block: Block) -> String {
        block.lines.map { layoutTrimmed($0.text) }.joined(separator: "\n")
    }

    private static func makeMessage(
        _ block: Block,
        role: ChatLayoutRole,
        kind: ChatLayoutKind,
        thresholds: ChatLayoutThresholds
    ) -> ChatLayoutMessage {
        let text = blockText(block)
        let confidence = block.lines.map { $0.confidence }.min() ?? 0
        return ChatLayoutMessage(
            role: role,
            text: text,
            box: block.box,
            confidence: confidence,
            kind: kind,
            bubble: block.bubble,
            suggestedText: kind.isChat
                ? suggestedTextWithoutSymbolNoise(text, confidence: confidence, thresholds: thresholds)
                : nil
        )
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// 自带一份 trim，不用 GoutouConfig.swift 里那份 String.trimmed：
/// 那个文件不在 tools/ChatLayoutCheck 的独立编译范围里，自己带着才能单飞。
private func layoutTrimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}
