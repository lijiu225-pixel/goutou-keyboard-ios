import Foundation

// 第二阶段的回归测试：气泡扫描、对齐轨道、聊天区域过滤、表情乱码建议。
//
// 这里的所有断言都是**纯逻辑**：喂进去的是自己造的像素行和归一化坐标，不碰 Vision。
// 真正跑 Vision 的那一套在 tools/ChatVisionCheck/main.swift（CI 上单独一步）。
//
// 版本一（匿名布局）的来历：下面那组坐标是从一张真实微信聊天截图上量出来的
// （画布底色 236、自己的气泡 #94EC68、对方的气泡 #FFFFFF；右侧 6 条气泡的右边缘都落在
// 0.8646...0.8672，左侧 5 条的左边缘都是 0.1354）。**文字已全部换成占位内容**，
// 只保留版式：私人聊天原文不提交到仓库。

// MARK: - 造像素

let stageLightCanvas = ChatRGB(byteRed: 236, byteGreen: 236, byteBlue: 236)
let stageLightBubbleOther = ChatRGB(byteRed: 255, byteGreen: 255, byteBlue: 255)
let stageLightBubbleMine = ChatRGB(byteRed: 148, byteGreen: 236, byteBlue: 104)
let stageDarkCanvas = ChatRGB(byteRed: 17, byteGreen: 17, byteBlue: 17)
let stageDarkBubbleOther = ChatRGB(byteRed: 44, byteGreen: 44, byteBlue: 44)
let stageDarkBubbleMine = ChatRGB(byteRed: 40, byteGreen: 96, byteBlue: 56)
let stageAvatar = ChatRGB(byteRed: 96, byteGreen: 74, byteBlue: 62)
let stageAvatarTwo = ChatRGB(byteRed: 150, byteGreen: 120, byteBlue: 130)

/// 按宽度比例拼一行像素（比例加起来不到 1 时用最后一个颜色补齐）。
func stageTwoRow(_ segments: [(Double, ChatRGB)], width: Int = 200) -> [ChatRGB] {
    var pixels: [ChatRGB] = []
    for (fraction, color) in segments {
        let count = max(1, Int((fraction * Double(width)).rounded()))
        for _ in 0..<count {
            pixels.append(color)
        }
    }
    while pixels.count < width {
        pixels.append(segments.last?.1 ?? stageLightCanvas)
    }
    if pixels.count > width {
        pixels = Array(pixels[0..<width])
    }
    return pixels
}

func stageTwoRows(_ segments: [(Double, ChatRGB)], width: Int = 200, height: Int = 1) -> ChatPixelRows? {
    let one = stageTwoRow(segments, width: width)
    var pixels: [ChatRGB] = []
    for _ in 0..<max(1, height) {
        pixels.append(contentsOf: one)
    }
    return ChatPixelRows(width: width, height: max(1, height), pixels: pixels)
}

func stageTwoLine(
    _ text: String,
    x: Double,
    y: Double,
    width: Double,
    height: Double = 0.017,
    confidence: Float = 0.9,
    bubble: (minX: Double, maxX: Double, tone: ChatBubbleTone)? = nil,
    avatar: ChatAvatarSide = .none,
    touchesLeftEdge: Bool = false,
    touchesRightEdge: Bool = false
) -> ChatOCRLine {
    let evidence = bubble.map { item in
        ChatBubbleEvidence(
            span: ChatBubbleSpan(
                minX: item.minX,
                maxX: item.maxX,
                tone: item.tone,
                touchesImageLeftEdge: touchesLeftEdge,
                touchesImageRightEdge: touchesRightEdge
            ),
            avatarSide: avatar
        )
    }
    return ChatOCRLine(
        text: text,
        box: ChatLayoutBox(x: x, y: y, width: width, height: height),
        confidence: confidence,
        bubble: evidence
    )
}

// MARK: - 匿名真实版式

/// 坐标来自真实截图，文字是占位内容。
///
/// 这一组数字专门锁住上一阶段的两个真实毛病：
///   * 长句的文字框几乎横跨整个内容区（0.1745...0.8672 的气泡里文字是 0.2031...0.8219），
///     所以「文字框贴左」这种判据必然把右侧消息判成「未确定」；
///   * 居中的日期、右侧绿色的通话记录「已取消」被当成普通聊天的。
let stageAnonymizedChatLines: [ChatOCRLine] = [
    stageTwoLine("06:33", x: 0.0953, y: 0.0259, width: 0.1852, height: 0.0162),
    stageTwoLine("张三", x: 0.4641, y: 0.0737, width: 0.0687, height: 0.0162),
    stageTwoLine(
        "示例消息一甲乙丙丁戊",
        x: 0.4305, y: 0.1389, width: 0.3937,
        bubble: (minX: 0.4008, maxX: 0.8664, tone: .greenish), avatar: .right
    ),
    stageTwoLine(
        "示例消息二",
        x: 0.1742, y: 0.1988, width: 0.1008,
        bubble: (minX: 0.1354, maxX: 0.3099, tone: .neutral), avatar: .left
    ),
    stageTwoLine(
        "示例消息三甲乙",
        x: 0.1742, y: 0.2574, width: 0.1727,
        bubble: (minX: 0.1354, maxX: 0.3828, tone: .neutral), avatar: .left
    ),
    stageTwoLine("9月21日 21:56", x: 0.4000, y: 0.3090, width: 0.2000, height: 0.0170),
    stageTwoLine(
        "示例消息四甲乙丙丁戊己庚辛壬癸",
        x: 0.2031, y: 0.3605, width: 0.6188,
        bubble: (minX: 0.1745, maxX: 0.8672, tone: .greenish), avatar: .right
    ),
    stageTwoLine(
        "示例消息五甲乙丙丁戊己庚辛",
        x: 0.2031, y: 0.3855, width: 0.5169,
        bubble: (minX: 0.1745, maxX: 0.8672, tone: .greenish), avatar: .right
    ),
    stageTwoLine(
        "示例消息六",
        x: 0.1758, y: 0.4433, width: 0.1023,
        bubble: (minX: 0.1354, maxX: 0.3099, tone: .neutral), avatar: .left
    ),
    stageTwoLine(
        "示例消息七甲乙丙丁 C",
        x: 0.4555, y: 0.5026, width: 0.3687, confidence: 0.3,
        bubble: (minX: 0.4245, maxX: 0.8672, tone: .greenish), avatar: .right
    ),
    stageTwoLine(
        "示例消息八甲乙丙丁戊己こ",
        x: 0.2125, y: 0.6326, width: 0.6086, confidence: 0.3,
        bubble: (minX: 0.1823, maxX: 0.8646, tone: .greenish), avatar: .right
    ),
    stageTwoLine(
        "示例消息九",
        x: 0.1742, y: 0.7031, width: 0.0664,
        bubble: (minX: 0.1354, maxX: 0.2734, tone: .neutral), avatar: .left
    ),
    stageTwoLine(
        "示例消息十甲乙丙丁戊己庚辛壬癸",
        x: 0.2125, y: 0.7622, width: 0.6086,
        bubble: (minX: 0.1823, maxX: 0.8672, tone: .greenish), avatar: .right
    ),
    stageTwoLine("9月21日 23:06", x: 0.4000, y: 0.8130, width: 0.2000, height: 0.0170),
    stageTwoLine(
        "已取消·",
        x: 0.6469, y: 0.8669, width: 0.1758,
        bubble: (minX: 0.6172, maxX: 0.8672, tone: .greenish), avatar: .right
    ),
];

// MARK: - 断言

func runStageTwoChecks() {
    // Missing bubble evidence must not turn a call status into copied chat.
    let missingCallBubble = ChatLayoutParser.analyze(lines: [
        stageTwoLine("甲甲甲", x: 0.18, y: 0.20, width: 0.2,
                     bubble: (minX: 0.135, maxX: 0.45, tone: .neutral)),
        stageTwoLine("已取消", x: 0.68, y: 0.40, width: 0.15),
        stageTwoLine("他说已取消", x: 0.18, y: 0.60, width: 0.3,
                     bubble: (minX: 0.135, maxX: 0.55, tone: .neutral)),
    ])
    expect(missingCallBubble.messages.first { $0.text == "已取消" }?.kind.reason == .callRecord,
           "No bubble: exact call status remains a recoverable candidate")
    expect(missingCallBubble.messages.first { $0.text == "他说已取消" }?.isKept == true,
           "A normal sentence containing call words must remain chat")
    let edgeReview = ChatLayoutParser.analyze(lines: [
        stageTwoLine("边缘真实消息", x: 0.18, y: 0.02, width: 0.30),
        stageTwoLine("甲甲甲", x: 0.18, y: 0.30, width: 0.20,
                     bubble: (minX: 0.135, maxX: 0.45, tone: .neutral)),
        stageTwoLine("乙乙乙", x: 0.55, y: 0.60, width: 0.20,
                     bubble: (minX: 0.5, maxX: 0.865, tone: .greenish)),
        stageTwoLine("底部真实消息", x: 0.55, y: 0.90, width: 0.30),
    ])
    expect(edgeReview.reviewMessages.map { $0.text } == ["边缘真实消息", "甲甲甲", "乙乙乙", "底部真实消息"],
           "Potentially ignored edge messages must survive in reading order for recovery")
    expect(edgeReview.reviewMessages.filter { $0.isKept }.count == 2,
           "Ignored edge content is excluded from copy until explicitly restored")
    var restored = edgeReview.reviewMessages
    restored[0].isKept = true
    restored[0].role = .other
    // Simulate the user's explicit role correction before copying this synthetic fixture.
    restored[1].role = .other
    restored[2].role = .me
    let exportMessages = restored.filter { $0.isKept }.compactMap { message -> GoutouChatClipboardMessage? in
        guard let role = message.role.clipboardRole else { return nil }
        return GoutouChatClipboardMessage(role: role, text: message.text)
    }
    expect(exportMessages.count == 3, "All selected roles must be confirmed before export")
    let exportText = try? GoutouChatClipboardCodec.encode(GoutouChatClipboardPayload(messages: exportMessages))
    let exportBack = exportText.flatMap { try? GoutouChatClipboardCodec.decode($0) }
    expect(exportBack?.messages.map { $0.text } == ["边缘真实消息", "甲甲甲", "乙乙乙"],
           "Restored content enters the JSON in reading order; unselected candidates stay out")

    // ── 1. 气泡扫描：底色估计 ───────────────────────────────────────────

    let leftRowSegments: [(Double, ChatRGB)] = [
        (0.10, stageAvatar),
        (0.04, stageLightCanvas),
        (0.30, stageLightBubbleOther),
        (0.56, stageLightCanvas),
    ]
    let rightRowSegments: [(Double, ChatRGB)] = [
        (0.56, stageLightCanvas),
        (0.30, stageLightBubbleMine),
        (0.04, stageLightCanvas),
        (0.10, stageAvatarTwo),
    ]
    // 高度取 20 行：气泡判定要看「色块纵向厚度 vs 文字框高度」，
    // 只有一行的图量不出厚度。
    guard let leftRows = stageTwoRows(leftRowSegments, width: 200, height: 20) else {
        fatalError("造不出测试像素行")
    }
    guard let rightRows = stageTwoRows(rightRowSegments, width: 200, height: 20) else {
        fatalError("造不出测试像素行")
    }

    let lightBackground = ChatBubbleScanner.background(of: leftRows)
    expect(lightBackground != nil, "必须能估出画布底色")
    expect(
        (lightBackground ?? stageLightCanvas).distance(to: stageLightCanvas) < 0.02,
        "浅色画布底色应该估成 236 灰，实际 \(String(describing: lightBackground))"
    )

    let leftSpans = ChatBubbleScanner.spans(
        inRow: leftRows.row(atIndex: 0),
        background: lightBackground ?? stageLightCanvas
    )
    expect(leftSpans.count == 2, "左边一行应该是「头像 + 白气泡」两块，实际 \(leftSpans.count)")
    expect(
        abs(leftSpans[0].minX - 0) < 0.02 && abs(leftSpans[0].maxX - 0.10) < 0.02,
        "头像色块的范围，实际 \(leftSpans[0].minX)...\(leftSpans[0].maxX)"
    )
    expect(
        leftSpans[1].minX > 0.12 && leftSpans[1].maxX < 0.46 && leftSpans[1].tone == .neutral,
        "白气泡必须是中性的，实际 \(leftSpans[1])"
    )

    // 文字框落在白气泡里 → 气泡证据指向它，头像在左边。
    let leftEvidence = ChatBubbleScanner.evidence(
        forText: ChatLayoutBox(x: 0.22, y: 0.4, width: 0.14, height: 0.2),
        rows: leftRows,
        background: lightBackground ?? stageLightCanvas
    )
    expect(leftEvidence != nil, "白气泡里的文字必须能扫出气泡证据")
    expect(
        abs((leftEvidence?.span.minX ?? 0) - 0.14) < 0.03
            && abs((leftEvidence?.span.maxX ?? 0) - 0.44) < 0.03,
        "扫出来的气泡范围要贴住白气泡，实际 \(String(describing: leftEvidence?.span))"
    )
    expect(leftEvidence?.avatarSide == .left, "左边有头像色块时必须认出来")

    // 右边：绿气泡 + 右侧头像。
    let rightBackground = ChatBubbleScanner.background(of: rightRows)
    let rightEvidence = ChatBubbleScanner.evidence(
        forText: ChatLayoutBox(x: 0.64, y: 0.4, width: 0.14, height: 0.2),
        rows: rightRows,
        background: rightBackground ?? stageLightCanvas
    )
    expect(rightEvidence?.avatarSide == .right, "右边有头像色块时必须认出来")
    expect(rightEvidence?.span.tone == .greenish, "绿气泡要认成偏绿")

    // ── 2. 深色模式走同一条路 ─────────────────────────────────────────

    guard let darkRows = stageTwoRows([
        (0.50, stageDarkCanvas),
        (0.20, stageDarkBubbleOther),
        (0.10, stageDarkCanvas),
        (0.20, stageDarkBubbleMine),
    ], width: 200, height: 1) else {
        fatalError("造不出深色测试像素行")
    }
    let darkBackground = ChatBubbleScanner.background(of: darkRows)
    expect(darkBackground != nil, "深色截图也要能估出底色")
    let darkSpans = ChatBubbleScanner.spans(
        inRow: darkRows.row(atIndex: 0),
        background: darkBackground ?? stageDarkCanvas
    )
    expect(darkSpans.count == 2, "深色模式下两块气泡都要认出来，实际 \(darkSpans.count)")
    expect(darkSpans[0].tone == .neutral, "对方气泡在深色模式下还是中性")
    expect(darkSpans[1].tone == .greenish, "自己的气泡在深色模式下依然偏绿")

    // ── 3. 笔画/压缩造成的小缝隙要补上，但不能把两块气泡并起来 ──────────

    var holePixels: [ChatRGB] = Array(repeating: stageLightCanvas, count: 100)
    holePixels += Array(repeating: stageLightBubbleOther, count: 40)
    holePixels.append(stageLightCanvas)
    holePixels += Array(repeating: stageLightBubbleOther, count: 40)
    holePixels += Array(repeating: stageLightCanvas, count: 19)
    guard let holeRows = ChatPixelRows(width: 200, height: 1, pixels: holePixels) else {
        fatalError("造不出带缝隙的像素行")
    }
    let holeSpans = ChatBubbleScanner.spans(inRow: holeRows.row(atIndex: 0), background: stageLightCanvas)
    expect(holeSpans.count == 1, "1 像素的缝隙要补上，实际 \(holeSpans.count) 块")
    expect(
        abs(holeSpans[0].minX - 0.50) < 0.02 && abs(holeSpans[0].maxX - 0.905) < 0.02,
        "补完缝隙之后的宽度要对，实际 \(holeSpans[0].minX)...\(holeSpans[0].maxX)"
    )

    // ── 3b. 裸文字（居中日期、状态栏时间）不能当成气泡 ────────────────

    // 一行只有笔画、没有气泡填充的文字：色块只有字那么宽、笔画之间露出底色、
    // 纵向厚度就是字高。这三条任何一条过不了都不该给气泡证据。
    var textOnlyPixels = [ChatRGB](repeating: stageLightCanvas, count: 200 * 20)
    for row in 8...12 {
        var column = 60
        while column < 140 {
            for offset in 0..<8 where column + offset < 200 {
                textOnlyPixels[row * 200 + column + offset] = ChatRGB(
                    byteRed: 60,
                    byteGreen: 60,
                    byteBlue: 60
                )
            }
            column += 10
        }
    }
    guard let textOnlyRows = ChatPixelRows(width: 200, height: 20, pixels: textOnlyPixels) else {
        fatalError("造不出裸文字像素")
    }
    let textOnlyEvidence = ChatBubbleScanner.evidence(
        forText: ChatLayoutBox(x: 0.32, y: 8.0 / 19.0, width: 0.36, height: 5.0 / 19.0),
        rows: textOnlyRows,
        background: stageLightCanvas
    )
    expect(
        textOnlyEvidence == nil,
        "一行孤零零的文字（居中日期那种）不能当成气泡，实际 \(String(describing: textOnlyEvidence?.span))"
    )

    // ── 4. 真实（匿名）版式：这就是上一阶段翻车的那张图 ────────────────

    let anonymized = ChatLayoutParser.analyze(lines: stageAnonymizedChatLines)
    let headerCount = anonymized.excludedCounts.first { $0.reason == .header }?.count ?? 0
    expect(headerCount == 2, "状态栏时间和聊天标题必须被剔掉，实际 \(headerCount)")
    expect(
        anonymized.messages.count == 12,
        "16 行并成 12 条（多行气泡算一条、页眉剔掉两条），实际 \(anonymized.messages.count)"
    )

    let anonymizedChat = anonymized.messages.filter { $0.kind.isChat }
    expect(anonymizedChat.count == 9, "其中 9 条是聊天消息，实际 \(anonymizedChat.count)")
    expect(
        anonymizedChat.map { $0.role } == [.me, .other, .other, .me, .other, .me, .me, .other, .me],
        "真实版式下的归属要全对，实际 \(anonymizedChat.map { $0.role.displayName })"
    )

    let anonymizedCandidates = anonymized.messages.filter { $0.kind.isCandidate }
    expect(anonymizedCandidates.count == 3, "三条候选（两个日期 + 一个通话记录），实际 \(anonymizedCandidates.count)")
    expect(
        anonymizedCandidates.map { $0.kind.reason } == [.dateSeparator, .dateSeparator, .callRecord],
        "候选的类型要分清，实际 \(anonymizedCandidates.map { String(describing: $0.kind.reason) })"
    )
    expect(anonymizedCandidates.allSatisfy { !$0.isKept }, "非聊天候选默认不进剪贴板")
    expect(anonymizedChat.allSatisfy { $0.isKept }, "聊天消息默认要进剪贴板")

    // ── 5. 表情被认成杂字：只给建议，不自动改 ────────────────────────

    expect(
        anonymized.messages.first { $0.text.hasSuffix(" C") }?.suggestedText == "示例消息七甲乙丙丁",
        "末尾孤立字母要给出「去掉」的建议，实际 \(String(describing: anonymized.messages.first { $0.text.hasSuffix(" C") }?.suggestedText))"
    )
    expect(
        anonymized.messages.first { $0.text.hasSuffix("こ") }?.suggestedText == "示例消息八甲乙丙丁戊己",
        "紧贴汉字的假名也要给出建议，实际 \(String(describing: anonymized.messages.first { $0.text.hasSuffix("こ") }?.suggestedText))"
    )
    expect(
        anonymized.messages.first { $0.text.hasSuffix(" C") }?.text == "示例消息七甲乙丙丁 C",
        "给建议不等于改正文：正文必须原样保留"
    )
    expect(
        ChatLayoutParser.suggestedTextWithoutSymbolNoise(
            "示例消息七甲乙丙丁 C",
            confidence: 0.9,
            thresholds: .default
        ) == nil,
        "置信度高时不许给建议（怕把「我选 C」这种真实内容改掉）"
    )
    expect(
        ChatLayoutParser.suggestedTextWithoutSymbolNoise(
            "我选 C",
            confidence: 0.3,
            thresholds: .default
        ) == nil,
        "正文汉字不足两个就不给建议"
    )

    // ── 6. 系统内容的文字特征：靠词也要靠版式 ────────────────────────

    expect(ChatLayoutParser.isDateOrTimeSeparator("9月21日 21:56"), "中文日期时间")
    expect(ChatLayoutParser.isDateOrTimeSeparator("2024年9月21日"), "带年份的日期")
    expect(ChatLayoutParser.isDateOrTimeSeparator("昨天 21:56"), "昨天 + 时间")
    expect(ChatLayoutParser.isDateOrTimeSeparator("星期三"), "星期几")
    expect(ChatLayoutParser.isDateOrTimeSeparator("21:56"), "只有时间")
    expect(
        !ChatLayoutParser.isDateOrTimeSeparator("明天21:56"),
        "「明天21:56」不是日期分隔（没有「月/日」结构），不能因为像时间就吞掉"
    )
    expect(!ChatLayoutParser.isDateOrTimeSeparator("我们21:56见"), "句子里夹时间不算分隔")
    expect(ChatLayoutParser.isSystemNotice("对方撤回了一条消息"), "撤回提示")
    expect(ChatLayoutParser.isSystemNotice("「张三」拍了拍我"), "拍一拍")
    expect(ChatLayoutParser.isCallRecord("已取消"), "通话记录：已取消")
    expect(ChatLayoutParser.isCallRecord("已取消·"), "通话记录：带尾巴的已取消")
    expect(ChatLayoutParser.isCallRecord("通话时长 00:12"), "通话记录：时长")
    expect(!ChatLayoutParser.isCallRecord("他说已取消"), "包含匹配不算通话记录（不能吃掉正常聊天）")
    expect(
        !ChatLayoutParser.isCallRecord("已取消的事情就这么定了甲甲甲甲甲甲甲"),
        "长句子不算通话记录"
    )

    // 有气泡的「明天21:56」是真聊天：不能只凭像时间就剔。
    let realTimeMessage = ChatLayoutParser.analyze(lines: [
        stageTwoLine("甲甲甲", x: 0.18, y: 0.10, width: 0.20,
                     bubble: (minX: 0.135, maxX: 0.38, tone: .neutral), avatar: .left),
        stageTwoLine("明天21:56", x: 0.55, y: 0.30, width: 0.25,
                     bubble: (minX: 0.50, maxX: 0.86, tone: .greenish), avatar: .right),
        stageTwoLine("乙乙乙", x: 0.18, y: 0.50, width: 0.20,
                     bubble: (minX: 0.135, maxX: 0.32, tone: .neutral), avatar: .left),
    ])
    expect(
        realTimeMessage.messages.allSatisfy { $0.kind.isChat },
        "有气泡的「明天21:56」必须当成正常聊天"
    )
    expect(
        realTimeMessage.messages.map { $0.role } == [.other, .me, .other],
        "这三条的归属也要对，实际 \(realTimeMessage.messages.map { $0.role.displayName })"
    )

    // 居中的日期 / 系统提示 → 候选，默认不复制。
    let separatorResult = ChatLayoutParser.analyze(lines: [
        stageTwoLine("甲甲甲", x: 0.18, y: 0.10, width: 0.20,
                     bubble: (minX: 0.135, maxX: 0.38, tone: .neutral), avatar: .left),
        stageTwoLine("9月21日 21:56", x: 0.42, y: 0.30, width: 0.16),
        stageTwoLine("对方撤回了一条消息", x: 0.34, y: 0.40, width: 0.32),
        stageTwoLine("乙乙乙", x: 0.55, y: 0.60, width: 0.20,
                     bubble: (minX: 0.50, maxX: 0.86, tone: .greenish), avatar: .right),
    ])
    let separatorReasons = separatorResult.messages.compactMap { $0.kind.reason }
    expect(
        separatorReasons.contains(.dateSeparator),
        "居中的日期要成为「日期时间」候选，实际 \(separatorReasons)"
    )
    expect(
        separatorReasons.contains(.systemNotice),
        "居中的撤回提示要成为「系统提示」候选，实际 \(separatorReasons)"
    )
    expect(
        separatorResult.messages.filter { $0.kind.isCandidate }.allSatisfy { !$0.isKept },
        "候选默认都不复制"
    )

    // ── 7. 键盘：一行挤着好几个小方块、连着好几行 → 整体剔掉 ──────────

    var keyboardLines: [ChatOCRLine] = [
        stageTwoLine("甲甲甲", x: 0.18, y: 0.10, width: 0.20,
                     bubble: (minX: 0.135, maxX: 0.45, tone: .neutral), avatar: .left),
        stageTwoLine("乙乙乙", x: 0.50, y: 0.35, width: 0.25,
                     bubble: (minX: 0.45, maxX: 0.86, tone: .greenish), avatar: .right),
    ]
    for row in 0..<3 {
        let y = 0.55 + Double(row) * 0.09
        for column in 0..<6 {
            keyboardLines.append(
                stageTwoLine("q", x: 0.04 + Double(column) * 0.16, y: y, width: 0.10)
            )
        }
    }
    let keyboardResult = ChatLayoutParser.analyze(lines: keyboardLines)
    let keyboardCount = keyboardResult.excludedCounts.first { $0.reason == .keyboard }?.count ?? 0
    expect(keyboardCount == 18, "键盘 3 行 × 6 键要整体剔掉，实际 \(keyboardCount)")
    expect(keyboardResult.messages.count == 2, "只剩上面两条真消息，实际 \(keyboardResult.messages.count)")

    // ── 8. 轨道：只有一侧 / 两边一样贴 / 被裁到边缘 ────────────────────

    let onlyLeft = ChatLayoutParser.parse(lines: [
        stageTwoLine("甲甲甲", x: 0.18, y: 0.10, width: 0.20,
                     bubble: (minX: 0.135, maxX: 0.30, tone: .neutral), avatar: .left),
        stageTwoLine("乙乙乙", x: 0.18, y: 0.30, width: 0.20,
                     bubble: (minX: 0.135, maxX: 0.44, tone: .neutral), avatar: .left),
    ])
    expect(
        onlyLeft.allSatisfy { $0.role == .other },
        "所有气泡共用左边缘、没有右侧参照 → 都是对方（有气泡证据时才敢这么判）"
    )

    let onlyRight = ChatLayoutParser.parse(lines: [
        stageTwoLine("甲甲甲", x: 0.60, y: 0.10, width: 0.20,
                     bubble: (minX: 0.55, maxX: 0.865, tone: .greenish), avatar: .right),
        stageTwoLine("乙乙乙", x: 0.75, y: 0.30, width: 0.20,
                     bubble: (minX: 0.70, maxX: 0.865, tone: .greenish), avatar: .right),
    ])
    expect(
        onlyRight.allSatisfy { $0.role == .me },
        "所有气泡共用右边缘 → 都是我"
    )

    let floatingBubble = ChatLayoutParser.parse(lines: [
        stageTwoLine("甲乙丙", x: 0.42, y: 0.30, width: 0.16,
                     bubble: (minX: 0.40, maxX: 0.58, tone: .neutral)),
    ])
    expect(floatingBubble.count == 1, "一条气泡就是一条")
    expect(
        floatingBubble[0].role == .unknown,
        "孤零零一条居中气泡、没轨道没头像，必须老实标未确定"
    )

    let fullWidthTie = ChatLayoutParser.parse(lines: [
        stageTwoLine("甲甲甲", x: 0.10, y: 0.10, width: 0.80,
                     bubble: (minX: 0.05, maxX: 0.95, tone: .greenish)),
        stageTwoLine("乙乙乙", x: 0.10, y: 0.40, width: 0.80,
                     bubble: (minX: 0.05, maxX: 0.95, tone: .greenish)),
    ])
    expect(
        fullWidthTie.allSatisfy { $0.role == .me },
        "两边贴得一样近的整屏宽气泡，用偏绿辅助判「我」"
    )

    let clippedLeft = ChatLayoutParser.parse(lines: [
        stageTwoLine("甲甲甲甲", x: 0.02, y: 0.10, width: 0.40,
                     bubble: (minX: 0.0, maxX: 0.42, tone: .neutral),
                     touchesLeftEdge: true),
        stageTwoLine("乙乙乙", x: 0.18, y: 0.30, width: 0.20,
                     bubble: (minX: 0.135, maxX: 0.38, tone: .neutral), avatar: .left),
        stageTwoLine("丙丙丙", x: 0.18, y: 0.50, width: 0.20,
                     bubble: (minX: 0.135, maxX: 0.30, tone: .neutral), avatar: .left),
    ])
    expect(
        clippedLeft.map { $0.role } == [.other, .other, .other],
        "被截图裁到左边缘的气泡按贴左算，实际 \(clippedLeft.map { $0.role.displayName })"
    )

    // 没有气泡证据时，必须还是上一阶段的老口径（不许借「新算法」之名乱猜）。
    let noEvidence = ChatLayoutParser.parse(lines: [
        stageTwoLine("甲甲甲", x: 0.05, y: 0.10, width: 0.30),
        stageTwoLine("乙乙乙", x: 0.05, y: 0.20, width: 0.25),
    ])
    expect(
        noEvidence.allSatisfy { $0.role == .unknown },
        "没有气泡证据、只有一侧时必须老实标未确定（老口径保留）"
    )

    // ── 9. 坐标换算的回归：降采样截图不许被整体放大 ───────────────────

    let downscaledMapper = ChatOCRCoordinateMapper(
        originalWidth: 1290,
        originalHeight: 2796,
        workingWidth: 1107.3,
        workingHeight: 2400,
        scale: 2400.0 / 2796.0
    )
    let unitBox = ChatLayoutBox(x: 0.2, y: 0.3, width: 0.1, height: 0.02)
    expect(
        downscaledMapper.normalizedBox(fromWorkingNormalized: unitBox) == unitBox,
        "工作图归一化和原图归一化在均匀缩放下相等，换算必须是恒等"
    )
    let zeroOriginMapped = downscaledMapper.map(
        lines: [ChatOCRLine(text: "占位", box: unitBox, confidence: 1)],
        tileOrigin: .zero
    )
    expect(zeroOriginMapped.count == 1, "换算出结果")
    expect(
        abs(zeroOriginMapped[0].box.minX - 0.2) < 0.002
            && abs(zeroOriginMapped[0].box.minY - 0.3) < 0.002,
        "单次识别按「原点在 0 的一片」换算后必须落回原处，实际 \(zeroOriginMapped[0].box)"
    )

    // ── 10. 结果契约：未确定不许进剪贴板 ──────────────────────────────

    let unresolved = ChatLayoutMessage(
        role: .unknown,
        text: "示例",
        box: ChatLayoutBox(x: 0.1, y: 0.1, width: 0.2, height: 0.02),
        confidence: 0.9
    )
    expect(unresolved.needsReview, "未确定要能被界面识别出来")
    expect(unresolved.isKept, "聊天消息默认参与复制（归属的事由复制流程再问）")
    expect(unresolved.role.clipboardRole == nil, "未确定不许直接写进剪贴板")

    let candidate = ChatLayoutMessage(
        role: .me,
        text: "已取消",
        box: ChatLayoutBox(x: 0.6, y: 0.8, width: 0.2, height: 0.02),
        confidence: 0.9,
        kind: .nonChatCandidate(.callRecord)
    )
    expect(!candidate.isKept, "非聊天候选默认不进剪贴板")
    expect(candidate.role.clipboardRole == .me, "候选被放回来后照样能带归属")
}
