import CoreGraphics
import CoreText
import Foundation

// 真实 Vision 的合成回归（CI 上跑，macOS runner）。
//
// 和 tools/ChatLayoutCheck 的分工：
//   * ChatLayoutCheck 是**纯逻辑**：喂进去的是手写的归一化坐标和像素行，一次 Vision 都不调；
//   * 这里是**真 OCR**：现场用 CoreGraphics 画一张匿名聊天截图，交给 ChatOCRService
//     走和 App 完全同一套识别 / 裁片 / 坐标换算 / 气泡扫描 / 版式解析，再断言结果。
//
// 合成坐标过了不等于 OCR 过了，所以这两步刻意分开、都要跑。
// 画出来的图里只有一个假人「张三」和几条占位消息，不含任何真实聊天内容。

struct SyntheticChatMessage {
    let text: String
    let isMine: Bool
    /// 居中的灰色系统文字（日期分隔）。
    let isSystem: Bool
    /// 气泡里文字左边的图标宽度（通话记录有个话筒/摄像头图标）。
    let iconWidth: Double

    init(text: String, isMine: Bool, isSystem: Bool = false, iconWidth: Double = 0) {
        self.text = text
        self.isMine = isMine
        self.isSystem = isSystem
        self.iconWidth = iconWidth
    }
}

// MARK: - 画图

private func chatLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    return CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes)
    )
}

private func lineWidth(_ line: CTLine) -> Double {
    Double(CTLineGetTypographicBounds(line, nil, nil, nil))
}

/// 左上原点的矩形 → CoreGraphics 的左下原点矩形。
private func topRect(_ x: Double, _ top: Double, _ width: Double, _ height: Double, imageHeight: Int) -> CGRect {
    CGRect(x: x, y: Double(imageHeight) - top - height, width: width, height: height)
}

private func drawText(_ line: CTLine, font: CTFont, x: Double, baselineFromTop: Double, context: CGContext, imageHeight: Int) {
    context.textPosition = CGPoint(x: x, y: Double(imageHeight) - baselineFromTop)
    CTLineDraw(line, context)
}

func renderSyntheticChat(
    width: Int,
    height: Int,
    dark: Bool,
    messages: [SyntheticChatMessage]
) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let canvas = dark
        ? CGColor(red: 0.066, green: 0.066, blue: 0.066, alpha: 1)
        : CGColor(red: 0.925, green: 0.925, blue: 0.925, alpha: 1)
    // 页眉/页脚条的颜色刻意贴近画布：真机上微信的导航栏和输入栏底色也只比聊天区
    // 深/浅一点点（距离 0.05 上下，低于扫描阈值 0.06）。这里要测的是「按内容边界剔页眉页脚」，
    // 不是「认出一块和画布不一样的大色块」，所以不能让它们自己变成伪气泡。
    let headerFill = dark
        ? CGColor(red: 0.070, green: 0.070, blue: 0.070, alpha: 1)
        : CGColor(red: 0.928, green: 0.928, blue: 0.928, alpha: 1)
    let bubbleMine = dark
        ? CGColor(red: 0.16, green: 0.38, blue: 0.22, alpha: 1)
        : CGColor(red: 0.60, green: 0.925, blue: 0.42, alpha: 1)
    let bubbleOther = dark
        ? CGColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1)
        : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    let textColor = dark
        ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        : CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
    let systemColor = dark
        ? CGColor(red: 0.62, green: 0.62, blue: 0.62, alpha: 1)
        : CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)

    context.setFillColor(canvas)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // 状态栏 + 导航栏（都要被剔掉）
    context.setFillColor(headerFill)
    context.fill(topRect(0, 0, Double(width), 200, imageHeight: height))

    let bodyFont = CTFontCreateWithName("PingFang SC" as CFString, 30, nil)
    let statusFont = CTFontCreateWithName("PingFang SC" as CFString, 26, nil)
    let systemFont = CTFontCreateWithName("PingFang SC" as CFString, 24, nil)

    let statusLine = chatLine("06:33", font: statusFont, color: textColor)
    drawText(statusLine, font: statusFont, x: 48, baselineFromTop: 60, context: context, imageHeight: height)

    let titleLine = chatLine("张三", font: bodyFont, color: textColor)
    drawText(
        titleLine,
        font: bodyFont,
        x: (Double(width) - lineWidth(titleLine)) / 2,
        baselineFromTop: 168,
        context: context,
        imageHeight: height
    )

    // 底部输入条（也要被剔掉）。这里画一条灰色的输入提示文字：
    // 它在聊天区下方，必须按「内容边界」被判成页脚，而不是靠一个固定高度的裁切带。
    context.setFillColor(headerFill)
    context.fill(topRect(0, Double(height) - 170, Double(width), 170, imageHeight: height))
    let placeholderLine = chatLine("输入消息", font: bodyFont, color: systemColor)
    drawText(
        placeholderLine,
        font: bodyFont,
        x: 120,
        baselineFromTop: Double(height) - 105,
        context: context,
        imageHeight: height
    )

    // 聊天内容
    var top = 240.0
    let margin = 26.0
    let avatarSize = 84.0
    let gap = 14.0
    let padding = 26.0
    let bubbleHeight = 96.0
    let maxBubbleWidth = Double(width) * 0.62

    for message in messages {
        if message.isSystem {
            let line = chatLine(message.text, font: systemFont, color: systemColor)
            drawText(
                line,
                font: systemFont,
                x: (Double(width) - lineWidth(line)) / 2,
                baselineFromTop: top + 40,
                context: context,
                imageHeight: height
            )
            top += 104
            continue
        }

        let line = chatLine(message.text, font: bodyFont, color: textColor)
        let bubbleWidth = min(
            maxBubbleWidth,
            lineWidth(line) + padding * 2 + message.iconWidth
        )
        let bubbleX = message.isMine
            ? Double(width) - margin - avatarSize - gap - bubbleWidth
            : margin + avatarSize + gap

        context.addPath(
            CGPath(
                roundedRect: topRect(bubbleX, top, bubbleWidth, bubbleHeight, imageHeight: height),
                cornerWidth: 18,
                cornerHeight: 18,
                transform: nil
            )
        )
        context.setFillColor(message.isMine ? bubbleMine : bubbleOther)
        context.fillPath()

        if message.iconWidth > 0 {
            context.addPath(
                CGPath(
                    roundedRect: topRect(bubbleX + 20, top + 28, message.iconWidth - 12, 40, imageHeight: height),
                    cornerWidth: 8,
                    cornerHeight: 8,
                    transform: nil
                )
            )
            context.setFillColor(dark ? bubbleMine : bubbleMine)
            context.fillPath()
        }

        let avatarX = message.isMine ? Double(width) - margin - avatarSize : margin
        context.addPath(
            CGPath(
                roundedRect: topRect(avatarX, top, avatarSize, avatarSize, imageHeight: height),
                cornerWidth: 12,
                cornerHeight: 12,
                transform: nil
            )
        )
        context.setFillColor(CGColor(red: 0.42, green: 0.36, blue: 0.32, alpha: 1))
        context.fillPath()
        context.addPath(
            CGPath(
                roundedRect: topRect(avatarX + 20, top + 20, 34, 34, imageHeight: height),
                cornerWidth: 8,
                cornerHeight: 8,
                transform: nil
            )
        )
        context.setFillColor(CGColor(red: 0.74, green: 0.68, blue: 0.62, alpha: 1))
        context.fillPath()

        let ascent = Double(CTFontGetAscent(bodyFont))
        let descent = Double(CTFontGetDescent(bodyFont))
        let baselineFromTop = top + (bubbleHeight - (ascent + descent)) / 2 + ascent
        drawText(
            line,
            font: bodyFont,
            x: bubbleX + padding + message.iconWidth,
            baselineFromTop: baselineFromTop,
            context: context,
            imageHeight: height
        )
        top += bubbleHeight + 30
    }

    return context.makeImage()
}

// MARK: - 检查

func runVisionSyntheticCheck(dark: Bool) -> [String] {
    var failures: [String] = []
    let label = dark ? "深色" : "浅色"

    let messages: [SyntheticChatMessage] = [
        SyntheticChatMessage(text: "第一条对方消息", isMine: false),
        SyntheticChatMessage(text: "第二条我自己的话", isMine: true),
        SyntheticChatMessage(text: "第三条对方的话", isMine: false),
        SyntheticChatMessage(text: "9月21日 21:56", isMine: false, isSystem: true),
        SyntheticChatMessage(text: "第四条我的话", isMine: true),
        SyntheticChatMessage(text: "已取消", isMine: true, iconWidth: 60),
    ]

    // 高度 2900：最长边超过 2400 会被降采样到 2400，正好压到「单次识别」那条路径，
    // 同时逼出「工作图归一化 -> 原图归一化」的换算（就是那个会把内容放大到右下角的坑）。
    let width = 820
    let height = 2900
    guard let image = renderSyntheticChat(width: width, height: height, dark: dark, messages: messages) else {
        return ["渲染合成截图失败"]
    }

    let result: ChatOCRResult
    do {
        result = try ChatOCRService.recognizeSync(cgImage: image)
    } catch {
        return ["合成截图的 Vision 识别失败：\(error)"]
    }
    if result.isEmpty {
        return ["\(label)：合成截图一张字都没认出来"]
    }
    if result.strategy != .singlePass {
        failures.append("\(label)：820x2900 应该走单次识别，实际 \(result.strategy)")
    }

    print("[\(label)] Vision 认出的原始行（含气泡证据）：")
    for line in result.lines {
        let bubbleText = line.bubble.map { evidence in
            "气泡=[\(round(evidence.span.minX * 1000) / 1000),\(round(evidence.span.maxX * 1000) / 1000)]"
                + " 头像=\(evidence.avatarSide.rawValue)"
        } ?? "无气泡"
        let boxText = "[\(round(line.box.minX * 1000) / 1000),\(round(line.box.minY * 1000) / 1000),"
            + "\(round(line.box.maxX * 1000) / 1000),\(round(line.box.maxY * 1000) / 1000)]"
        print("    box=\(boxText) \(bubbleText) \(line.text)")
    }

    // 分析图自检：确认「行 0 是图像顶部」这个假设成立，并看清每一行到底有没有色块。
    if let scan = ChatOCRScanContext.make(from: image) {
        let bg = scan.background
        print(
            "[\(label)] 分析图 \(scan.rows.width)x\(scan.rows.height) "
                + "底色=(\\(round(bg.red * 255)),\\(round(bg.green * 255)),\\(round(bg.blue * 255)))"
        )
        for probe in [0.02, 0.06, 0.10, 0.14, 0.19, 0.24, 0.31, 0.90, 0.96] {
            let rowIndex = scan.rows.rowIndex(forNormalizedY: probe)
            let row = scan.rows.row(atIndex: rowIndex)
            var first = -1
            var last = -1
            var count = 0
            for (offset, pixel) in row.enumerated() where pixel.distance(to: bg) > 0.06 {
                count += 1
                if first < 0 { first = offset }
                last = offset
            }
            print("    分析行 y=\(probe) row=\(rowIndex) 非底色列=\(count) 首=\(first) 尾=\(last)")
        }
    }
    let analysis = ChatLayoutParser.analyze(lines: result.lines)

    // 把这次真 OCR 认出来的每一行都写进日志（都是合成文字，不含任何真实内容），
    // 断言失败时能一眼看出是「没认出来」还是「认出来了但判错」。
    print("[\(label)] Vision 认出的行：")
    for message in analysis.messages {
        let reason = message.kind.reason.map { "非聊天(\($0.displayName))" } ?? "聊天"
        print(
            "    \(reason) role=\(message.role.displayName) "
                + "box=[\(round(message.box.minX * 1000) / 1000),\(round(message.box.minY * 1000) / 1000)] "
                + "\(message.text)"
        )
    }
    let excludedText = analysis.excludedCounts
        .map { "\($0.reason.displayName) \($0.count)" }
        .joined(separator: "、")
    print("[\(label)] 被剔掉：\(excludedText.isEmpty ? "无" : excludedText)")

    // 页眉（状态栏时间 / 聊天标题）和页脚（输入提示）都必须按内容边界剔掉，
    // 而不是靠「固定裁掉顶部 N 像素」。
    let header = analysis.excludedCounts.first { $0.reason == .header }?.count ?? 0
    if header < 1 {
        failures.append("\(label)：状态栏/标题必须被剔掉，实际页眉剔了 \(header) 条")
    }
    let footer = analysis.excludedCounts.first { $0.reason == .footer }?.count ?? 0
    if footer < 1 {
        failures.append("\(label)：底部输入提示必须被剔掉，实际页脚剔了 \(footer) 条")
    }

    // 4 条聊天消息的归属必须全对，而且**一条都不许是「未确定」**（这正是本阶段要修的毛病）。
    let chatExpectation: [(needle: String, role: ChatLayoutRole)] = [
        ("第一条", .other),
        ("第二条", .me),
        ("第三条", .other),
        ("第四条", .me),
    ]
    var matchedChat = 0
    for item in chatExpectation {
        guard let message = analysis.messages.first(where: { $0.text.contains(item.needle) }) else {
            failures.append("\(label)：没找到含「\(item.needle)」的消息")
            continue
        }
        matchedChat += 1
        if !message.kind.isChat {
            failures.append("\(label)：「\(item.needle)」应该是普通聊天，实际 \(message.kind)")
        }
        if message.role == .unknown {
            failures.append("\(label)：「\(item.needle)」不该是「未确定」")
        } else if message.role != item.role {
            failures.append(
                "\(label)：「\(item.needle)」的归属应该是 \(item.role.displayName)，实际 \(message.role.displayName)"
            )
        }
    }
    // Vision 在合成图上偶尔会漏掉一行，这里只要求 4 条里至少认出 3 条；
    // 真正卡的是「认出来的那些必须判对」。
    if matchedChat < 3 {
        failures.append("\(label)：4 条聊天消息只认出 \(matchedChat) 条，太少了")
    }

    // 日期分隔和通话记录是本阶段的核心目标，必须成立。
    if let dateMessage = analysis.messages.first(where: { $0.text.contains("9月21日") }) {
        if dateMessage.kind.reason != .dateSeparator {
            failures.append("\(label)：居中的日期应该是「日期时间」候选，实际 \(dateMessage.kind)")
        }
        if dateMessage.isKept {
            failures.append("\(label)：日期候选默认不该被复制")
        }
    } else {
        failures.append("\(label)：没找到日期分隔那一行")
    }
    if let callMessage = analysis.messages.first(where: { $0.text.contains("已取消") }) {
        if callMessage.kind.reason != .callRecord {
            failures.append("\(label)：绿气泡里的「已取消」应该是通话记录候选，实际 \(callMessage.kind)")
        }
        if callMessage.isKept {
            failures.append("\(label)：通话记录候选默认不该被复制")
        }
    } else {
        failures.append("\(label)：没找到通话记录那一行")
    }
    if analysis.messages.contains(where: { $0.text.contains("输入消息") }) {
        failures.append("\(label)：底部输入提示被当成聊天消息了")
    }

    print(
        "[\(label)] 识别 \(result.lines.count) 行 -> 聊天 "
            + "\(analysis.messages.filter { $0.kind.isChat }.count) 条、候选 "
            + "\(analysis.messages.filter { $0.kind.isCandidate }.count) 条、剔掉 \(analysis.excludedTotal) 行"
    )
    return failures
}

let problems = runVisionSyntheticCheck(dark: false) + runVisionSyntheticCheck(dark: true)
for problem in problems {
    print("FAIL: \(problem)")
}
if problems.isEmpty {
    print("ChatVisionCheck passed")
} else {
    exit(1)
}
