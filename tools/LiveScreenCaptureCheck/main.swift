import Foundation

/// 阶段 12A 的纯逻辑契约：状态机、节流、单 OCR in-flight、最新待处理帧、阅读顺序，
/// 以及「这一层不写任何东西」的结构性保证。
///
/// 这里**不碰** ScreenCaptureKit / Vision 引擎，也不联网：真实的 picker、SCStream、
/// 微信前台跨 App 捕获只能由真机验证。
var checks = 0
func expect(_ value: Bool, _ description: String) {
    checks += 1
    if !value { fatalError("LiveScreenCaptureCheck: \(description)") }
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

// MARK: - 1 / 2：初始状态与不支持

var model = LiveScreenCaptureModel(isSupported: true)
expect(model.state == .idle, "初始是 idle")
expect(model.framesReceived == 0 && model.ocrRuns == 0 && model.snapshot == nil, "初始没有计数与结果")
expect(model.state.canStart && !model.state.canStop, "idle 只能开始，不能停止")

let unsupported = LiveScreenCaptureModel(isSupported: false)
expect(unsupported.state == .unsupported, "系统不支持时是 unsupported")
expect(!unsupported.state.canStart, "unsupported 不能开始")
expect(unsupported.state.title.contains("iOS 27"), "要告诉用户需要 iOS 27")

// MARK: - 3 / 5 / 6：开始流程与重复开始

expect(model.beginStart(), "idle 可以开始")
expect(model.state == .presentingPicker, "先等系统 picker")
expect(model.pickerDidSelectContent(), "选好内容后进入 starting")
expect(model.state == .starting, "starting")
expect(model.captureDidStart(), "startCapture 成功 → capturing")
expect(model.state == .capturing, "capturing")
expect(!model.beginStart(), "捕获中再点开始会被挡下（不建第二条 stream）")
expect(model.state == .capturing, "被挡下时状态不变")

// MARK: - 9 / 12 / 13 / 14 / 16 / 17：帧、节流、单 OCR in-flight

expect(model.receiveScreenFrame(at: t0) == .runOCR, "第一帧立刻跑 OCR")
model.ocrDidStart(at: t0)
expect(model.ocrRuns == 1, "OCR 次数 +1")
expect(model.isOCRInFlight, "OCR 进行中")
expect(model.receiveScreenFrame(at: t0.addingTimeInterval(0.1)) == .holdPending, "OCR 期间只留最新帧")
expect(model.receiveScreenFrame(at: t0.addingTimeInterval(0.2)) == .holdPending, "还是同一个 pending 槽")
expect(model.hasPendingFrame, "确实有一帧在等")

let first = LiveOCRSnapshot(timestamp: t0, strings: ["第一帧"])
expect(!model.ocrDidFinish(generation: model.generation, result: .success(first), at: t0.addingTimeInterval(0.3)),
       "节流窗口内不立刻处理 pending 帧")
expect(model.snapshot == first, "成功结果写进最新 snapshot")
expect(model.droppedFrames == 1, "窗口内排不上队的 pending 帧按设计丢掉")

expect(model.receiveScreenFrame(at: t0.addingTimeInterval(0.4)) == .throttled, "窗口内、又没在跑 OCR：直接丢帧")
expect(model.droppedFrames == 2, "丢帧计数")
expect(model.receiveScreenFrame(at: t0.addingTimeInterval(1.2)) == .runOCR, "过了节流窗口可以再跑 OCR")
model.ocrDidStart(at: t0.addingTimeInterval(1.2))
let second = LiveOCRSnapshot(timestamp: t0.addingTimeInterval(1.2), strings: ["第二帧"])
_ = model.ocrDidFinish(generation: model.generation, result: .success(second), at: t0.addingTimeInterval(1.3))
expect(model.snapshot == second, "新 snapshot 替换旧的（只留一份）")
expect(model.ocrRuns == 2, "OCR 次数累计")

// 15：OCR 完成时如果还有最新帧在等、且窗口允许 → 立刻再跑一次
expect(model.receiveScreenFrame(at: t0.addingTimeInterval(2.5)) == .runOCR, "窗口过了又能跑")
model.ocrDidStart(at: t0.addingTimeInterval(2.5))
_ = model.receiveScreenFrame(at: t0.addingTimeInterval(2.6))
let third = LiveOCRSnapshot(timestamp: t0.addingTimeInterval(2.6), strings: ["第三帧"])
expect(model.ocrDidFinish(generation: model.generation, result: .success(third), at: t0.addingTimeInterval(3.4)),
       "有 pending 帧且窗口允许 → 调用方应当立刻再跑一次")

// MARK: - 21：OCR 失败不停 stream，后续帧继续

let failuresBefore = model.ocrFailures
model.ocrDidStart(at: t0.addingTimeInterval(4.5))
expect(!model.ocrDidFinish(generation: model.generation,
                           result: .failure(LiveOCRFailure("这一帧识别失败")),
                           at: t0.addingTimeInterval(4.6)),
       "失败时没有 pending 帧就什么都不做")
expect(model.state == .capturing, "OCR 失败不影响捕获状态")
expect(model.ocrFailures == failuresBefore + 1, "失败次数 +1")
expect(model.receiveScreenFrame(at: t0.addingTimeInterval(5.5)) == .runOCR, "失败之后后续帧照常跑")

// MARK: - 19 / 20：停止后迟到的 OCR 结果不得写回

let staleGeneration = model.generation
model.ocrDidStart(at: t0.addingTimeInterval(5.5))
let snapshotBeforeStop = model.snapshot
expect(model.beginStop(), "可以停止")
expect(model.state == .stopping, "stopping")
let late = LiveOCRSnapshot(timestamp: t0.addingTimeInterval(5.7), strings: ["迟到结果"])
expect(!model.ocrDidFinish(generation: staleGeneration, result: .success(late), at: t0.addingTimeInterval(5.7)),
       "停止之后迟到的结果一律丢掉")
expect(model.snapshot == snapshotBeforeStop, "late 结果没污染最新 snapshot")
expect(model.state == .stopping, "late 结果不会把状态改回 capturing")

// MARK: - 7 / 8：停止只停一次，多次停止安全

expect(!model.beginStop(), "第二次 stop 不做重复动作")
model.captureDidStop()
expect(model.state == .stopped, "停止完成 → stopped")
model.captureDidStop()
expect(model.state == .stopped, "重复 captureDidStop 不崩、状态不变")
expect(!model.state.canStop, "stopped 不能再点停止")
expect(model.state.canStart, "stopped 可以重新开始")

// MARK: - 22 / 23：stream 挂了 → failed，之后允许重新开始

expect(model.beginStart(), "stopped 可以重新开始")
_ = model.pickerDidSelectContent()
model.captureDidFail("屏幕共享被系统结束")
expect(model.state == .failed("屏幕共享被系统结束"), "fatal failure → failed")
expect(model.lastErrorReason == "屏幕共享被系统结束", "记住失败原因")
expect(model.state.canStart, "failed 之后可以重新开始")
expect(model.beginStart(), "重新开始成功")

// MARK: - 4：用户取消 picker

model.pickerDidCancel()
expect(model.state == .idle, "用户取消 picker → idle")
expect(!model.state.canStop, "取消后不在捕获状态")

// MARK: - 10 的一半：没在捕获时收到帧只计数

var idleModel = LiveScreenCaptureModel()
expect(idleModel.receiveScreenFrame(at: t0) == .ignore, "没在捕获时的帧只计数")
expect(idleModel.framesReceived == 1, "帧数照样 +1")
expect(idleModel.snapshot == nil, "没捕获就不会有结果")

// MARK: - 19（阅读顺序）：上 → 下，同行左 → 右

let lines = [
    LiveScreenOCRProcessor.Line(text: "第二行右边", box: CGRect(x: 0.50, y: 0.30, width: 0.3, height: 0.05)),
    LiveScreenOCRProcessor.Line(text: "第一行左", box: CGRect(x: 0.10, y: 0.80, width: 0.3, height: 0.05)),
    LiveScreenOCRProcessor.Line(text: "   ", box: CGRect(x: 0.10, y: 0.50, width: 0.1, height: 0.05)),
    LiveScreenOCRProcessor.Line(text: "第一行右", box: CGRect(x: 0.60, y: 0.80, width: 0.3, height: 0.05)),
]
expect(LiveScreenOCRProcessor.readingOrder(lines) == ["第一行左", "第一行右", "第二行右边"],
       "阅读顺序：先上后下、同行左到右，空白行丢掉")
expect(LiveScreenOCRProcessor.readingOrder([]).isEmpty, "空输入返回空")

// MARK: - 24 / 25 / 26 / 29：一整轮不写文件、不写共享聊天、不写 UserDefaults

let fm = FileManager.default
let probeRoot = fm.temporaryDirectory.appendingPathComponent("LiveScreenCaptureCheck-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: probeRoot, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: probeRoot) }
let before = try fm.contentsOfDirectory(atPath: probeRoot.path)
var cycle = LiveScreenCaptureModel()
_ = cycle.beginStart()
_ = cycle.pickerDidSelectContent()
_ = cycle.captureDidStart()
_ = cycle.receiveScreenFrame(at: t0)
cycle.ocrDidStart(at: t0)
_ = cycle.ocrDidFinish(generation: cycle.generation,
                       result: .success(LiveOCRSnapshot(timestamp: t0, strings: ["虚构图"])),
                       at: t0.addingTimeInterval(1))
_ = cycle.beginStop()
cycle.captureDidStop()
let after = try fm.contentsOfDirectory(atPath: probeRoot.path)
expect(before == after, "一整轮捕获 + OCR 不往磁盘写任何文件")
expect(UserDefaults.standard.object(forKey: "goutou.live.screen.capture") == nil, "不写 UserDefaults")
let store = SharedChatStore(testContainer: probeRoot)
var wroteSharedChat = false
do { _ = try store.read(); wroteSharedChat = true } catch { wroteSharedChat = false }
expect(!wroteSharedChat, "不写共享聊天文件")

// MARK: - 27 / 28 / 29 / 30：动态识别模块的源码里不该出现的调用

let liveSourceFiles = [
    "App/ScreenCapture/LiveOCRSnapshot.swift",
    "App/ScreenCapture/LiveScreenCaptureState.swift",
    "App/ScreenCapture/LiveScreenOCRProcessor.swift",
    "App/ScreenCapture/LiveScreenCaptureManager.swift",
    "App/LiveScreenCaptureView.swift",
]
let forbiddenTokens = [
    "GoutouAIClient", "URLSession", "textDocumentProxy", "insertText",
    "UIImageWriteToSavedPhotosAlbum", "PHPhotoLibrary", "AVCaptureDevice", "AVAudioSession",
    "UserDefaults", "SharedChatStore", "runMemoryExtraction", "saveSummary", "deleteBackward",
]
for file in liveSourceFiles {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
        expect(false, "读不到源码文件 \(file)")
        continue
    }
    for token in forbiddenTokens {
        // 阶段 12C 起，捕获管理器里确实出现了 SharedChatStore —— 但只在用户点
        // 「保存给狗头军师」时的手动交接里（LiveChatReviewSaver）。「识别过程绝不自动写共享聊天」
        // 由 LiveChatReviewCheck 的行为测试把关（跑完整识别流程后容器里不该出现文件）。
        if token == "SharedChatStore" && file.hasSuffix("LiveScreenCaptureManager.swift") { continue }
        expect(!text.contains(token), "\(file) 不该出现 \(token)")
    }
}

print("LiveScreenCaptureCheck passed (\(checks) assertions; pure logic only; no ScreenCaptureKit, no network)")
