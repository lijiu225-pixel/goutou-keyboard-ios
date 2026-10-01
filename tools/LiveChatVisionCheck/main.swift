import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import Vision

// The device screenshot is never uploaded. Only anonymous text and matching proportions
// are rendered here, through the actual live probe and full-frame OCR implementations.
func renderDevice(counter: String) -> CVPixelBuffer {
    let width = 1280, height = 2781
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
    context.setFillColor(CGColor(gray: 0.93, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    func text(_ value: String, x: CGFloat, baseline: CGFloat, size: CGFloat = 54, white: Bool = false) {
        let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: white ? 1 : 0, alpha: 1)
        ]))
        context.textPosition = CGPoint(x: x * CGFloat(width), y: (1 - baseline) * CGFloat(height))
        CTLineDraw(line, context)
    }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0.30 * CGFloat(width), y: 0.947 * CGFloat(height),
                        width: 0.34 * CGFloat(width), height: 0.04 * CGFloat(height)))
    text(counter, x: 0.32, baseline: 0.042, size: 40, white: true)
    text("17:10", x: 0.08, baseline: 0.042, size: 40)
    text("合成联系人甲", x: 0.36, baseline: 0.095, size: 48)
    text("顶部被裁切的合成消息", x: 0.18, baseline: 0.145)
    for (index, line) in ["第一条合成消息", "第二条合成消息", "第三条合成消息", "第四条合成消息"].enumerated() {
        text(line, x: index % 2 == 0 ? 0.07 : 0.58, baseline: 0.22 + CGFloat(index) * 0.15)
    }
    text("输入消息", x: 0.16, baseline: 0.945)
    return pixelBuffer
}

func renderTenBubbles(dark: Bool) -> CVPixelBuffer {
    let width = 1280, height = 2781
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
    context.setFillColor(CGColor(gray: dark ? 0.055 : 0.94, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, color: CGColor) {
        let box = CGRect(x: x * CGFloat(width), y: (1 - y - h) * CGFloat(height),
                         width: w * CGFloat(width), height: h * CGFloat(height))
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.fillPath()
    }
    func text(_ value: String, x: CGFloat, top: CGFloat, color: CGColor, size: CGFloat = 50) {
        let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]))
        context.textPosition = CGPoint(x: x * CGFloat(width), y: (1 - top - 0.017) * CGFloat(height))
        CTLineDraw(line, context)
    }
    let foreground = CGColor(gray: dark ? 0.96 : 0.04, alpha: 1)
    text("00:11", x: 0.07, top: 0.028, color: foreground, size: 42)
    text("合成甲", x: 0.435, top: 0.074, color: foreground)
    text("8月20日 星期四 01:51", x: 0.345, top: 0.242, color: CGColor(gray: 0.50, alpha: 1), size: 32)
    text("你撤回了一条消息", x: 0.395, top: 0.222, color: CGColor(gray: 0.50, alpha: 1), size: 32)
    let green = CGColor(red: 0.13, green: 0.72, blue: 0.38, alpha: 1)
    let other = CGColor(gray: dark ? 0.17 : 1, alpha: 1)
    let rows: [(Bool, CGFloat, [String])] = [
        (true, 0.140, ["第一条长消息的开头请完整识别出来", "第一条长消息的中间", "第一条长消息的结尾"]),
        (true, 0.281, ["第二条完整回复的开头这是匿名测试", "第二条完整回复的结尾"]),
        (false, 0.366, ["收到啦"]),
        (false, 0.426, ["别着急慢慢来"]),
        (false, 0.486, ["现在可以了"]),
        (false, 0.547, ["第六条长消息的开头请完整识别出来", "第六条长消息的结尾"]),
        (false, 0.627, ["我还在外面呢"]),
        (false, 0.687, ["待会再回去"]),
        (false, 0.748, ["第九条长消息的开头请完整识别出来", "第九条长消息的结尾"]),
        (true, 0.823, ["最后一条回复的开头请完整识别出来", "最后一条回复的结尾"]),
    ]
    for (mine, y, lines) in rows {
        let bubbleWidth: CGFloat = lines.count > 1 ? 0.67 : CGFloat(lines[0].count) * 50 / CGFloat(width) + 0.052
        let bubbleX: CGFloat = mine ? 0.855 - bubbleWidth : 0.145
        rect(bubbleX, y - 0.012, bubbleWidth, CGFloat(lines.count - 1) * 0.024 + 0.041, color: mine ? green : other)
        rect(mine ? 0.89 : 0.027, y - 0.012, 0.09, 0.041, color: CGColor(gray: 0.42, alpha: 1))
        for (offset, value) in lines.enumerated() {
            // Multiline right bubbles start at the left padding; short right text
            // is right anchored by its own compact bubble.
            text(value, x: bubbleX + 0.026, top: y + CGFloat(offset) * 0.024,
                 color: mine ? CGColor(gray: 0.02, alpha: 1) : foreground)
        }
    }
    rect(0.11, 0.918, 0.69, 0.044, color: CGColor(gray: dark ? 0.17 : 1, alpha: 1))
    return pixelBuffer
}

var checks = 0
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fatalError("LiveChatVisionCheck: \(message)") }
}

let baseline = renderDevice(counter: "0")
let probe = try ChatSceneProbe.recognize(pixelBuffer: baseline, orientation: .up, languages: ["zh-Hans", "en-US"])
let full = try LiveScreenOCRProcessor.recognize(pixelBuffer: baseline, orientation: .up)
print("Live OCR observations=\(full.observations.count) nav=\(probe.navigationLineCount) rows=\(probe.messageRowCount)")
expect(full.observations.filter { $0.text.contains("合成消息") }.count >= 3, "full-frame OCR reads device-sized message text")
let refined = ChatSceneDetector.refining(probe, with: full.observations)
expect(refined.hasNavigationBar, "full-frame OCR recovers navigation missed by the separate title probe")
expect(refined.topBarFingerprint != nil, "navigation selects a contact identity")

var pipeline = LiveChatScenePipeline()
for frame in 0..<5 {
    let buffer = renderDevice(counter: String(frame))
    let evidence = try ChatSceneProbe.recognize(pixelBuffer: buffer, orientation: .up, languages: ["zh-Hans", "en-US"])
    let snapshot = try LiveScreenOCRProcessor.recognize(pixelBuffer: buffer, orientation: .up)
    pipeline.detect(ChatSceneDetector.refining(evidence, with: snapshot.observations))
    _ = pipeline.ingest(snapshot.observations, at: Date(timeIntervalSince1970: Double(frame)))
}
expect(pipeline.snapshot().messages.count >= 3, "real live OCR accumulates messages despite changing island counts")
for dark in [false, true] {
    let image = renderTenBubbles(dark: dark)
    let probe = try ChatSceneProbe.recognize(pixelBuffer: image, orientation: .up, languages: ["zh-Hans", "en-US"])
    let full = try LiveScreenOCRProcessor.recognize(pixelBuffer: image, orientation: .up)
    let evidence = ChatSceneDetector.refining(probe, with: full.observations)
    var chat = LiveChatScenePipeline()
    for frame in 0..<4 {
        chat.detect(evidence)
        _ = chat.ingest(full.observations, at: Date(timeIntervalSince1970: Double(frame)))
    }
    let result = chat.snapshot()
    print("Ten-bubble Vision dark=\(dark) OCR=\(full.observations.count) input=\(evidence.inputTopRatio ?? -1) messages=\(result.messages.count) roles=\(result.messages.map { $0.role.rawValue })")
    expect(result.messages.count == 10, "actual Vision keeps all ten bubbles and excludes system labels in both themes")
    expect(result.messages.first?.text.contains("第一条长消息的开头") == true,
           "actual Vision preserves the first line below navigation")
    expect(result.messages.first?.text.contains("第一条长消息的结尾") == true,
           "actual Vision groups all lines of the first bubble")
    expect(result.messages.map(\.role) == [.me, .me, .other, .other, .other, .other, .other, .other, .other, .me],
           "actual Vision identifies both speakers from text inside bubbles")
}
print("LiveChatVisionCheck passed (\(checks) assertions; anonymous device proportions; actual live Vision path)")
