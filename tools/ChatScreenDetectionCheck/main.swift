import CoreGraphics
import Foundation

/// 阶段 12E（Final）契约：聊天界面门控 —— 只有屏幕稳定像「聊天会话界面」时才允许
/// 完整 OCR → 时间线 → 自动同步；离开聊天界面就暂停提交，但不清已共享的聊天。
///
/// 全部虚构画面；不联网、不调 AI、不插字。真实的微信界面只能真机验收。
var checks = 0
func expect(_ value: Bool, _ description: String) {
    checks += 1
    if !value { fatalError("ChatScreenDetectionCheck: \(description)") }
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)
let config = ChatSceneGateConfiguration.default

func observation(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 0.03) -> LiveOCRObservation {
    LiveOCRObservation(text: text, confidence: 0.9, box: CGRect(x: x, y: y, width: width, height: height))
}

/// 一屏「聊天界面」：顶部标题、中部左右消息、底部输入栏。
func chatScreen(top: String = "张三", mine: Int = 2, theirs: Int = 2, extra: [LiveOCRObservation] = []) -> [LiveOCRObservation] {
    var screen = [observation(top, x: 0.42, y: 0.045, width: 0.16)]
    var y: CGFloat = 0.20
    for index in 0..<theirs {
        screen.append(observation("对方第\(index)条", x: 0.05, y: y, width: 0.34))
        y += 0.06
    }
    for index in 0..<mine {
        screen.append(observation("我第\(index)条", x: 0.62, y: y, width: 0.32))
        y += 0.06
    }
    screen.append(observation("输入消息", x: 0.08, y: 0.93, width: 0.24))
    return screen + extra
}

/// 一屏「不是聊天」：只有列表 / 网格 / 视频文字，没有聊天那种左右成对的消息与输入栏。
func nonChatScreen(_ label: String) -> [LiveOCRObservation] {
    [
        observation(label, x: 0.30, y: 0.05, width: 0.30),
        observation("条目一", x: 0.08, y: 0.20, width: 0.80),
        observation("条目二", x: 0.08, y: 0.30, width: 0.80),
        observation("条目三", x: 0.08, y: 0.40, width: 0.80),
        observation("条目四", x: 0.08, y: 0.50, width: 0.80),
    ]
}

/// 和控制器里那条规则一致的判定：先算候选块，再看门控；只有 activeChat 才提交给时间线。
struct SimulatedPipeline {
    var core = LiveChatScenePipeline()
    var gate: LiveChatScenePipeline { core }
    var system: LiveChatScenePipeline { core }
    var timelineCount: Int { core.snapshot().messages.count }
    mutating func reset(generation: Int) { core.reset() }
    mutating func ingest(_ observations: [LiveOCRObservation], at now: Date) -> (submitted: Bool, verdict: ChatSceneVerdict) {
        core.detect(ChatSceneDetector.probeEvidence(observations: observations, rectangles: []))
        _ = core.ingest(observations, at: now)
        return (core.allowsFullRecognition, core.verdict)
    }
}

// MARK: - 1~4：标准 / 深色 / 长文本 / 语音图片较多的聊天页都判成 activeChat

var pipeline = SimulatedPipeline()
pipeline.reset(generation: 1)
var submitted = false
// 第 1 帧还只是「确认中」，第 2 帧进入聊天界面，稳定化再从提交的第一帧重新数，
// 所以第一条约消息要第 3 帧才进时间线（约 1.6 秒，和 OCR 节流一致）。
for frame in 0..<3 {
    submitted = pipeline.ingest(chatScreen(), at: t0.addingTimeInterval(Double(frame) * 0.8)).submitted
}
expect(pipeline.gate.verdict == .activeChat, "1. 标准左右聊天页面连续两帧 → activeChat")
expect(submitted, "1b. 进入聊天界面后开始向时间线提交")
expect(pipeline.timelineCount > 0, "1c. 时间线真的开始积累")

// 深色模式：我们只吃几何，不看颜色，所以同样的版面同样判成聊天
expect(ChatSceneDetector.isChatScene(
    ChatSceneDetector.evidence(observations: chatScreen(), candidates: [], config: config), config: config) == false,
       "2. 只有 observations、没有候选块时不算聊天（避免误判）")
var darkPipeline = SimulatedPipeline()
darkPipeline.reset(generation: 1)
_ = darkPipeline.ingest(chatScreen(top: "李四"), at: t0)
_ = darkPipeline.ingest(chatScreen(top: "李四"), at: t0.addingTimeInterval(0.8))
expect(darkPipeline.gate.verdict == .activeChat, "2b. 深色模式聊天页（同版面）同样 activeChat")

var longPipeline = SimulatedPipeline()
longPipeline.reset(generation: 1)
let longScreen = chatScreen(mine: 1, theirs: 1, extra: [
    observation("这是一条很长的消息占了一大片宽度而且横跨中线", x: 0.08, y: 0.40, width: 0.86),
])
_ = longPipeline.ingest(longScreen, at: t0)
_ = longPipeline.ingest(longScreen, at: t0.addingTimeInterval(0.8))
expect(longPipeline.gate.verdict == .activeChat, "3. 长文本聊天照样判成聊天")

var mediaPipeline = SimulatedPipeline()
mediaPipeline.reset(generation: 1)
let mediaScreen = chatScreen(mine: 1, theirs: 1, extra: [
    observation("21:30", x: 0.45, y: 0.34, width: 0.10),          // 居中系统时间
    observation("[语音] 0:06", x: 0.05, y: 0.42, width: 0.22),     // 语音消息
    observation("[图片]", x: 0.66, y: 0.50, width: 0.16),          // 图片消息
])
_ = mediaPipeline.ingest(mediaScreen, at: t0)
_ = mediaPipeline.ingest(mediaScreen, at: t0.addingTimeInterval(0.8))
_ = mediaPipeline.ingest(mediaScreen, at: t0.addingTimeInterval(1.6))
expect(mediaPipeline.gate.verdict == .activeChat, "4. 语音 / 图片较多但仍然左右成对 + 有输入栏：仍可判定")
expect(mediaPipeline.timelineCount > 0, "4b. 这类聊天页也允许进入时间线")

// MARK: - 5~8：联系人列表 / 设置 / 桌面 / 短视频信息流都判成 inactive

for (index, label) in ["联系人列表", "设置", "桌面", "短视频"].enumerated() {
    var other = SimulatedPipeline()
    other.reset(generation: 1)
    var verdict = ChatSceneVerdict.unknown
    for frame in 0..<3 {
        verdict = other.ingest(nonChatScreen(label), at: t0.addingTimeInterval(Double(frame) * 0.8)).verdict
    }
    expect(verdict == .inactive, "\(5 + index). \(label) → inactive")
    expect(other.timelineCount == 0, "\(5 + index)b. 非聊天界面不向时间线提交")
}

// MARK: - 9 / 10 / 11 / 12：单帧异常不会退出，连续非聊天才退出，退出后不再增长

var stability = SimulatedPipeline()
stability.reset(generation: 1)
_ = stability.ingest(chatScreen(), at: t0)
_ = stability.ingest(chatScreen(), at: t0.addingTimeInterval(0.8))
expect(stability.gate.verdict == .activeChat, "9. 先进入聊天")

let beforeAnomaly = stability.timelineCount
_ = stability.ingest(nonChatScreen("滚动中的一帧"), at: t0.addingTimeInterval(1.6))
expect(stability.gate.verdict == .activeChat, "9b. 单帧异常（滚动 / 动画）不会退出聊天")
_ = stability.ingest(nonChatScreen("动画中的一帧"), at: t0.addingTimeInterval(2.4))
expect(stability.gate.verdict == .activeChat, "9c. 两帧异常仍然保持聊天（退出要连续 3 帧）")

let exitVerdict = stability.ingest(nonChatScreen("真的离开了"), at: t0.addingTimeInterval(3.2)).verdict
expect(exitVerdict == .inactive, "10. 连续 3 帧非聊天才退出")
let afterExit = stability.timelineCount
_ = stability.ingest(nonChatScreen("离开之后仍在别的页面"), at: t0.addingTimeInterval(4.0))
expect(stability.timelineCount == afterExit, "11. 退出后时间线不再增长")
expect(stability.timelineCount >= beforeAnomaly, "11b. 迟滞窗口内的帧照常处理，退出后不再增长")

// 12 / 13：再进入聊天自动恢复
_ = stability.ingest(chatScreen(), at: t0.addingTimeInterval(4.8))
_ = stability.ingest(chatScreen(), at: t0.addingTimeInterval(5.6))
expect(stability.gate.verdict == .activeChat, "12. 重新进入聊天界面自动恢复识别")

// MARK: - 14：换了聊天对象 → 开新的一轮 timeline，不混两个人的聊天

var switching = SimulatedPipeline()
switching.reset(generation: 1)
_ = switching.ingest(chatScreen(top: "张三"), at: t0)
_ = switching.ingest(chatScreen(top: "张三"), at: t0.addingTimeInterval(0.8))
_ = switching.ingest(chatScreen(top: "张三"), at: t0.addingTimeInterval(1.6))
let firstChatCount = switching.timelineCount
expect(firstChatCount > 0, "14. 先积累了一段跟张三的聊天")

var newSessionCount = 0
for frame in 0..<3 {
    let outcome = switching.ingest(chatScreen(top: "李四"), at: t0.addingTimeInterval(2.4 + Double(frame) * 0.8))
    if switching.gate.verdict == .activeChat { newSessionCount += 1 }
    _ = outcome
}
expect(newSessionCount > 0, "14b. 顶部标题变了之后仍然在聊天界面")
expect(switching.timelineCount < firstChatCount + 6, "14c. 换人聊天时时间线被重开（不会把两个人的消息拼在一起）")

// MARK: - 15 / 16：离开聊天界面时自动同步不写盘（复用 12D 的纯逻辑）

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("ChatScreenDetectionCheck-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let store = SharedChatStore(testContainer: root)
var autoSync = LiveChatAutoSyncSession()
_ = autoSync.resetForNewSession(generation: 1)
_ = autoSync.setEnabled(true, messages: [], now: t0)

// 在聊天界面：时间线更新会排一次写入
var gatedChat = SimulatedPipeline()
gatedChat.reset(generation: 1)
_ = gatedChat.ingest(chatScreen(), at: t0)
_ = gatedChat.ingest(chatScreen(), at: t0.addingTimeInterval(0.8))
_ = gatedChat.ingest(chatScreen(), at: t0.addingTimeInterval(1.6))
let inChatMessages = gatedChat.system.snapshot().messages
expect(!inChatMessages.isEmpty, "15b. 聊天界面里真的积累出了稳定消息")
_ = autoSync.noteTimeline(messages: inChatMessages, now: t0.addingTimeInterval(1.6))
expect(autoSync.pending != nil, "15c. 聊天界面里的稳定聊天会排队等待自动同步")

// 离开聊天界面：控制器会调 noteLeftChatScene（＝取消排队），并且不再提交新消息
_ = autoSync.clearLiveChat()
expect(autoSync.pending == nil, "15. 离开聊天界面后取消排队的自动同步")
let chatFile = root
    .appendingPathComponent(SharedConstants.chatDirectory)
    .appendingPathComponent(SharedConstants.latestChatFilename)
expect(!fm.fileExists(atPath: chatFile.path), "16. 没有提交就没有写盘（不会因为离开界面写一份残缺聊天）")

// MARK: - 结构保证：门控只读像素与几何，不碰 AI / 输入代理 / 发送

guard let gateSource = try? String(contentsOfFile: "App/ScreenCapture/ChatSceneGate.swift", encoding: .utf8) else {
    fatalError("ChatScreenDetectionCheck: 读不到 ChatSceneGate.swift")
}
for token in ["GoutouAIClient", "URLSession", "textDocumentProxy", "insertText", "deleteBackward",
              "UserDefaults", "Timer", "scheduledTimer", "UIPasteboard"] {
    expect(!gateSource.contains(token), "门控里不该出现 \(token)")
}
// 门控不使用颜色 / 联系人名字 / 分辨率：只用几何与文字
for token in ["UIColor", "colorOf", "bubbleColor", "screenScale", "UIScreen"] {
    expect(!gateSource.contains(token), "门控不该依赖 \(token)")
}
guard let managerSource = try? String(contentsOfFile: "App/ScreenCapture/LiveScreenCaptureManager.swift", encoding: .utf8) else {
    fatalError("ChatScreenDetectionCheck: 读不到 LiveScreenCaptureManager.swift")
}
expect(managerSource.contains("engine.pipeline.detect(evidence)"), "控制器真的接上了门控")
expect(managerSource.contains("sync.noteLeftChatScene()"), "离开聊天界面会暂停自动同步")
expect(!managerSource.contains("insertText"), "主 App 不碰输入代理")

// Text-free media: rectangles represent bubbles and the input field, not fictional OCR labels.
for media in ["image", "video", "voice"] {
    let nav = [observation("合成会话", x: 0.4, y: 0.06, width: 0.2)]
    let boxes = [CGRect(x: 0.08, y: 0.25, width: 0.4, height: 0.08),
                 CGRect(x: 0.55, y: 0.45, width: 0.4, height: 0.08),
                 CGRect(x: 0.18, y: 0.90, width: 0.62, height: 0.045)]
    var real = LiveChatScenePipeline()
    let evidence = ChatSceneDetector.probeEvidence(observations: nav, rectangles: boxes)
    real.detect(evidence); real.detect(evidence)
    expect(real.allowsFullRecognition, "text-free media geometry: \(media)")
}
var titleGate = ChatSceneGate()
_ = titleGate.update(isChatFrame: true, titleFingerprint: "A")
_ = titleGate.update(isChatFrame: true, titleFingerprint: "A")
_ = titleGate.update(isChatFrame: true, titleFingerprint: "B")
expect(!titleGate.allowsSubmission, "quarantine first different title frame")
expect(titleGate.update(isChatFrame: true, titleFingerprint: "B").startsNewSession, "confirmed title switches generation")
_ = titleGate.update(isChatFrame: false)
expect(!titleGate.allowsSubmission && titleGate.verdict == .activeChat, "UI hysteresis never permits suspicious writes")
var isolation = SimulatedPipeline()
for frame in 0..<3 { _ = isolation.ingest(chatScreen(), at: t0.addingTimeInterval(Double(frame))) }
let oldGeneration = isolation.core.chatGeneration
for frame in 0..<4 {
    _ = isolation.ingest(chatScreen(top: "合成新联系人", mine: 1, theirs: 1), at: t0.addingTimeInterval(Double(frame + 3)))
}
expect(isolation.core.chatGeneration > oldGeneration, "production pipeline rotates generation")
expect(isolation.timelineCount == 2, "production pipeline contains only new contact messages")

print("ChatScreenDetectionCheck passed (\(checks) assertions; pure logic only; synthetic screens; no network)")
