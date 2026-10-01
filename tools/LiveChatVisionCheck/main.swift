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
expect(probe.hasNavigationBar, "accurate navigation OCR finds the visible contact")
expect(probe.topBarFingerprint != nil, "navigation selects a contact identity")

var pipeline = LiveChatScenePipeline()
for frame in 0..<5 {
    let buffer = renderDevice(counter: String(frame))
    let evidence = try ChatSceneProbe.recognize(pixelBuffer: buffer, orientation: .up, languages: ["zh-Hans", "en-US"])
    let snapshot = try LiveScreenOCRProcessor.recognize(pixelBuffer: buffer, orientation: .up)
    pipeline.detect(evidence)
    _ = pipeline.ingest(snapshot.observations, at: Date(timeIntervalSince1970: Double(frame)))
}
expect(pipeline.snapshot().messages.count >= 3, "real live OCR accumulates messages despite changing island counts")
print("LiveChatVisionCheck passed (\(checks) assertions; anonymous device proportions; actual live Vision path)")
