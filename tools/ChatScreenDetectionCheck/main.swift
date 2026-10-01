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

// MARK: - 真实微信版式的几何 fixture（全部虚构，不含任何真实聊天内容）

/// 真实微信版式：导航带（头像旁的名字 + 在线状态，偏左、多行）、左右气泡、居中日期、
/// 底部输入栏。输入栏**只给几何**——真机上微信输入框是空的，读不到「输入」两个字。
func weChatChatScreen(
    top: String = "合成联系人",
    mine: Int = 3,
    theirs: Int = 3,
    extraObservations: [LiveOCRObservation] = [],
    extraRectangles: [CGRect] = []
) -> (observations: [LiveOCRObservation], rectangles: [CGRect]) {
    var observations = [
        observation(top, x: 0.17, y: 0.050, width: 0.26),                     // 头像右边的名字
        observation("在线", x: 0.17, y: 0.085, width: 0.12),                   // 在线状态
        observation("9月30日 星期三 01:44", x: 0.36, y: 0.29, width: 0.28),    // 居中系统时间
    ]
    var y: CGFloat = 0.20
    for index in 0..<theirs {
        observations.append(observation("对方第\(index)条", x: 0.13, y: y, width: 0.34))
        y += 0.07
    }
    for index in 0..<mine {
        observations.append(observation("我第\(index)条", x: 0.34, y: y, width: 0.40))
        y += 0.07
    }
    var rectangles = [CGRect(x: 0.13, y: 0.63, width: 0.34, height: 0.05)]      // 图片消息占位
    rectangles.append(CGRect(x: 0.13, y: 0.925, width: 0.72, height: 0.028))    // 底部输入框
    return (observations + extraObservations, rectangles + extraRectangles)
}

/// 微信首页 / 联系人列表：通栏行 + 底部 tab，没有输入栏
func weChatListScreen() -> (observations: [LiveOCRObservation], rectangles: [CGRect]) {
    var observations = [observation("微信", x: 0.45, y: 0.05, width: 0.10)]
    var y: CGFloat = 0.16
    for index in 0..<6 {
        observations.append(observation("会话\(index)", x: 0.19, y: y, width: 0.52))
        y += 0.10
    }
    for (index, tab) in ["微信", "通讯录", "发现", "我"].enumerated() {
        observations.append(observation(tab, x: 0.08 + CGFloat(index) * 0.25, y: 0.94, width: 0.08))
    }
    return (observations, [])
}

/// 朋友圈 / 信息流：通栏内容块，没有左右气泡、没有输入栏
func weChatFeedScreen() -> (observations: [LiveOCRObservation], rectangles: [CGRect]) {
    var observations = [observation("朋友圈", x: 0.45, y: 0.05, width: 0.14)]
    var y: CGFloat = 0.16
    for index in 0..<5 {
        observations.append(observation("动态第\(index)条横跨整屏的一行字", x: 0.05, y: y, width: 0.90))
        y += 0.13
    }
    return (observations, [])
}

/// 抖音短视频：顶部关注 / 推荐，左下文案，右侧竖排窄图标
func shortVideoScreen() -> (observations: [LiveOCRObservation], rectangles: [CGRect]) {
    var observations = [
        observation("关注", x: 0.18, y: 0.05, width: 0.08),
        observation("推荐", x: 0.40, y: 0.05, width: 0.08),
        observation("合成作者", x: 0.06, y: 0.62, width: 0.30),
        observation("合成文案", x: 0.06, y: 0.70, width: 0.44),
    ]
    var y: CGFloat = 0.55
    for _ in 0..<4 {
        observations.append(observation("1.2万", x: 0.88, y: y, width: 0.09))
        y += 0.09
    }
    return (observations, [])
}

/// 普通网页 / 设置页：通栏正文，没有气泡也没有输入栏
func articleScreen() -> (observations: [LiveOCRObservation], rectangles: [CGRect]) {
    var observations = [observation("合成网页标题", x: 0.10, y: 0.05, width: 0.40)]
    var y: CGFloat = 0.16
    for index in 0..<6 {
        observations.append(observation("正文第\(index)段横跨整屏的一行字", x: 0.08, y: y, width: 0.84))
        y += 0.09
    }
    return (observations, [])
}

/// 跑若干帧真实版式，返回最终结论。
func runRealLayout(_ screen: (observations: [LiveOCRObservation], rectangles: [CGRect]),
                   frames: Int = 3) -> (verdict: ChatSceneVerdict, allows: Bool, messages: Int) {
    var pipeline = LiveChatScenePipeline()
    for frame in 0..<frames {
        pipeline.detect(ChatSceneDetector.probeEvidence(observations: screen.observations,
                                                        rectangles: screen.rectangles))
        _ = pipeline.ingest(screen.observations, at: t0.addingTimeInterval(Double(frame) * 0.8))
    }
    return (pipeline.verdict, pipeline.allowsFullRecognition, pipeline.snapshot().messages.count)
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

// 只有顶部标题、没有消息行：设置页 / 详情页那种结构不能算聊天
expect(ChatSceneDetector.isChatScene(
    ChatSceneDetector.probeEvidence(
        observations: [observation("合成会话", x: 0.4, y: 0.06, width: 0.2)],
        rectangles: [CGRect(x: 0.10, y: 0.30, width: 0.50, height: 0.12)]),
    config: config) == false,
       "2. 只有顶部标题、没有消息行时不算聊天（避免把设置页 / 详情页判成聊天）")
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

for (index, label) in ["联系人列表", "微信首页", "设置", "桌面", "短视频"].enumerated() {
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
_ = stability.ingest(nonChatScreen("设置"), at: t0.addingTimeInterval(1.6))
expect(stability.gate.verdict == .activeChat, "9b. 单帧异常（滚动 / 动画）不会退出聊天")
_ = stability.ingest(nonChatScreen("设置"), at: t0.addingTimeInterval(2.4))
expect(stability.gate.verdict == .activeChat, "9c. 两帧异常仍然保持聊天（退出要连续 3 帧）")

let exitVerdict = stability.ingest(nonChatScreen("设置"), at: t0.addingTimeInterval(3.2)).verdict
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

// MARK: - 真实版式回归：浅色 / 深色 / 单侧 / 图片语音为主都要判成聊天

expect(runRealLayout(weChatChatScreen()).verdict == .activeChat,
       "20. 浅色微信标准聊天（导航带 + 左右气泡 + 居中日期 + 底部输入栏）→ activeChat")
expect(runRealLayout(weChatChatScreen(top: "合成另一个联系人")).verdict == .activeChat,
       "21. 深色微信标准聊天（同版面，门控只看几何不看颜色）→ activeChat")
expect(runRealLayout(weChatChatScreen(mine: 0, theirs: 4)).verdict == .activeChat,
       "22. 只有左侧消息 + 输入栏 → activeChat")
expect(runRealLayout(weChatChatScreen(mine: 4, theirs: 0)).verdict == .activeChat,
       "23. 只有右侧消息 + 输入栏 → activeChat")
expect(runRealLayout((
    observations: [observation("合成会话", x: 0.4, y: 0.06, width: 0.20)],
    rectangles: [CGRect(x: 0.10, y: 0.20, width: 0.42, height: 0.16),
                 CGRect(x: 0.45, y: 0.40, width: 0.42, height: 0.16),
                 CGRect(x: 0.10, y: 0.60, width: 0.42, height: 0.12),
                 CGRect(x: 0.13, y: 0.925, width: 0.72, height: 0.028)])).verdict == .activeChat,
       "24. 图片多、文字少（只有气泡几何）→ activeChat")
expect(runRealLayout((
    observations: [observation("合成会话", x: 0.4, y: 0.06, width: 0.20),
                   observation("语音 3″", x: 0.13, y: 0.22, width: 0.16)],
    rectangles: [CGRect(x: 0.10, y: 0.20, width: 0.34, height: 0.05),
                 CGRect(x: 0.52, y: 0.34, width: 0.36, height: 0.05),
                 CGRect(x: 0.10, y: 0.48, width: 0.30, height: 0.05),
                 CGRect(x: 0.13, y: 0.925, width: 0.72, height: 0.028)])).verdict == .activeChat,
       "25. 语音多、文字少 → activeChat")
let avatarTitle = weChatChatScreen()
let avatarEvidence = ChatSceneDetector.probeEvidence(observations: avatarTitle.observations,
                                                    rectangles: avatarTitle.rectangles)
expect(avatarEvidence.navigationLineCount >= 2 && avatarEvidence.hasInputBar,
       "26. 标题带头像 + 在线状态：导航带算多行文字，不要求居中纯文字")
expect(runRealLayout(avatarTitle).verdict == .activeChat, "26b. 带头像 + 在线状态 → activeChat")

// 本次真机 Bug 的核心回归：灵动岛展开 / 通知横幅挡住导航栏，输入框也没被几何检测到，
// 只要中部同时有偏左和偏右的气泡行，仍然必须判成聊天。
let covered = weChatChatScreen()
let coveredEvidence = ChatSceneDetector.probeEvidence(
    observations: covered.observations.filter { $0.box.midY > 0.20 },
    rectangles: [])                       // 这一帧矩形检测什么都没找到（输入框没被认出来）
expect(!coveredEvidence.hasInputBar, "27. 这一帧确实没有检测到输入栏")
expect(!coveredEvidence.hasNavigationBar, "27b. 这一帧确实没有导航文字（被灵动岛挡住了）")
expect(ChatSceneDetector.isChatScene(coveredEvidence, config: config),
       "27c. 导航被挡 + 输入栏没识别到，只要左右气泡都在就仍然判聊天（修掉真机假阴性）")
expect(runRealLayout((observations: covered.observations.filter { $0.box.midY > 0.20 },
                      rectangles: [])).verdict == .activeChat,
       "27d. 这种帧连续出现也要进 activeChat")

// MARK: - 真实版式回归：非聊天页面必须保持 inactive

for (index, screen) in [weChatListScreen(), weChatFeedScreen(),
                        shortVideoScreen(), articleScreen()].enumerated() {
    let result = runRealLayout(screen)
    let name = ["联系人列表 / 微信首页", "朋友圈 / 信息流", "抖音短视频", "普通网页 / 设置页"][index]
    expect(result.verdict == (index == 3 ? .unknown : .inactive),
           "28.\(index)a known non-chat → inactive; ambiguous article geometry → unknown")
    expect(result.messages == 0, "28.\(index)b \(name) 不写时间线")
    expect(result.allows == false, "28.\(index)c \(name) 不进入完整识别")
}

// MARK: - 真实版式回归：滚动 / 动画的单帧异常不掉出聊天

var scrollPipeline = LiveChatScenePipeline()
let scrollScreen = weChatChatScreen(mine: 2, theirs: 2)
for frame in 0..<3 {
    scrollPipeline.detect(ChatSceneDetector.probeEvidence(observations: scrollScreen.observations,
                                                          rectangles: scrollScreen.rectangles))
    _ = scrollPipeline.ingest(scrollScreen.observations, at: t0.addingTimeInterval(Double(frame) * 0.8))
}
expect(scrollPipeline.verdict == .activeChat, "29. 先进入聊天")
let glitchScreen = ([observation("合成会话", x: 0.4, y: 0.06, width: 0.20)], [CGRect]())
scrollPipeline.detect(ChatSceneDetector.probeEvidence(observations: glitchScreen.0, rectangles: glitchScreen.1))
_ = scrollPipeline.ingest(glitchScreen.0, at: t0.addingTimeInterval(2.4))
expect(scrollPipeline.verdict == .activeChat, "30. 滚动 / 动画的一帧异常不掉出 activeChat")
scrollPipeline.detect(ChatSceneDetector.probeEvidence(observations: glitchScreen.0, rectangles: glitchScreen.1))
_ = scrollPipeline.ingest(glitchScreen.0, at: t0.addingTimeInterval(3.2))
expect(scrollPipeline.verdict == .activeChat, "30b. 两帧异常仍然保持聊天（退出要连续 3 帧）")
scrollPipeline.detect(ChatSceneDetector.probeEvidence(observations: scrollScreen.observations,
                                                      rectangles: scrollScreen.rectangles))
_ = scrollPipeline.ingest(scrollScreen.observations, at: t0.addingTimeInterval(4.0))
expect(scrollPipeline.verdict == .activeChat, "30c. 滚动结束后仍然 activeChat")

// 诊断文案只说结构，不含聊天正文
expect(!avatarEvidence.diagnostics.contains("对方第"), "31. 门控诊断不含聊天正文")
expect(avatarEvidence.diagnostics.contains("nav=yes") && avatarEvidence.diagnostics.contains("input=yes"),
       "31b. 门控诊断带 nav / input 标记")

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

let keyboardScreen = chatScreen().filter { $0.text != "输入消息" }
    + [observation("键盘合成文本", x: 0.05, y: 0.70, width: 0.30)]
let keyboardEvidence = ChatSceneDetector.probeEvidence(observations: keyboardScreen,
    rectangles: [CGRect(x: 0.18, y: 0.56, width: 0.62, height: 0.04)])
expect(keyboardEvidence.inputTopRatio == 0.56, "input area follows keyboard height")
var keyboardPipeline = LiveChatScenePipeline()
for frame in 0..<3 {
    keyboardPipeline.detect(keyboardEvidence)
    _ = keyboardPipeline.ingest(keyboardScreen, at: t0.addingTimeInterval(Double(frame)))
}
expect(keyboardPipeline.allowsFullRecognition, "chat remains active with keyboard open")
expect(!keyboardPipeline.snapshot().messages.contains { $0.text.contains("键盘合成文本") }, "keyboard text excluded from real timeline")

var shortExit = ChatSceneGate()
_ = shortExit.update(isChatFrame: true, titleFingerprint: "同名")
_ = shortExit.update(isChatFrame: true, titleFingerprint: "同名")
_ = shortExit.update(isChatFrame: false)
expect(shortExit.verdict == .activeChat, "single transition frame preserves display")
_ = shortExit.update(isChatFrame: true, titleFingerprint: "同名")
expect(!shortExit.allowsSubmission, "same-title short exit requires fresh confirmation")
expect(shortExit.update(isChatFrame: true, titleFingerprint: "同名").startsNewSession, "same-title short exit rotates session")
let delivery = LiveFrameDeliveryGate()
expect(delivery.acquire(), "first frame queued")
expect(!(0..<1000).contains { _ in delivery.acquire() }, "frame delivery queue is bounded")
delivery.release()
expect(delivery.acquire(), "delivery resumes after completion")
delivery.release()

// Missing navigation is uncertainty, never proof that the current contact owns this frame.
var hiddenTitle = LiveChatScenePipeline()
for frame in 0..<3 {
    hiddenTitle.detect(ChatSceneDetector.probeEvidence(observations: chatScreen(), rectangles: []))
    _ = hiddenTitle.ingest(chatScreen(), at: t0.addingTimeInterval(Double(frame)))
}
let hiddenTitleCount = hiddenTitle.snapshot().messages.count
let coveredOther = chatScreen(top: "另一个人").filter { $0.box.midY > 0.17 }.map {
    LiveOCRObservation(text: $0.text + "乙", confidence: $0.confidence, box: $0.box)
}
hiddenTitle.detect(ChatSceneDetector.probeEvidence(observations: coveredOther, rectangles: []))
_ = hiddenTitle.ingest(coveredOther, at: t0.addingTimeInterval(4))
expect(hiddenTitle.verdict == .activeChat, "covered title preserves recognition display")
expect(!hiddenTitle.allowsFullRecognition, "covered title quarantines messages instead of authorizing submission")
expect(hiddenTitle.snapshot().messages.count == hiddenTitleCount, "unconfirmed frames leave the official timeline intact")
expect(hiddenTitle.shouldRunOCR && hiddenTitle.pendingFrameCount == 1, "covered title continues OCR into memory only")

// Long weak-evidence runs must not turn missing features into a non-chat verdict.
let retainedGeneration = hiddenTitle.chatGeneration
let weakEvidence = ChatSceneDetector.probeEvidence(observations: [], rectangles: [])
for frame in 0..<20 {
    hiddenTitle.detect(weakEvidence)
    _ = hiddenTitle.ingest(coveredOther, at: t0.addingTimeInterval(Double(frame + 5)))
}
expect(hiddenTitle.verdict == .activeChat && hiddenTitle.exitStreak == 0, "weak evidence never accumulates exit frames")
expect(hiddenTitle.shouldRunOCR && !hiddenTitle.allowsFullRecognition, "weak evidence permits OCR but forbids submission")
expect(hiddenTitle.chatGeneration == retainedGeneration, "weak evidence does not rotate contact generation")
let wideMessages = [observation("长消息第一行的合成内容", x: 0.05, y: 0.2, width: 0.90),
                    observation("长消息第二行的合成内容", x: 0.05, y: 0.3, width: 0.90),
                    observation("长消息第三行的合成内容", x: 0.05, y: 0.4, width: 0.90)]
let wideEvidence = ChatSceneDetector.probeEvidence(observations: wideMessages, rectangles: [])
expect(!ChatSceneDetector.isClearlyNonChatScene(wideEvidence), "wide text alone is not affirmative non-chat evidence")
for _ in 0..<4 { hiddenTitle.detect(wideEvidence) }
expect(hiddenTitle.verdict == .activeChat && hiddenTitle.shouldRunOCR && !hiddenTitle.allowsFullRecognition,
       "covered single-sided long messages keep OCR active and submission held")
expect(hiddenTitle.pendingFrameCount == config.maximumPendingFrames, "pending frame capacity evicts oldest frames")
expect(hiddenTitle.pendingObservationCount <= config.maximumPendingObservations, "pending observation capacity is bounded")
expect(hiddenTitle.pendingCharacterCount <= config.maximumPendingCharacters, "pending text capacity is bounded")
hiddenTitle.detect(ChatSceneDetector.probeEvidence(observations: chatScreen(), rectangles: []))
_ = hiddenTitle.ingest(chatScreen(), at: t0.addingTimeInterval(30))
expect(hiddenTitle.allowsFullRecognition && hiddenTitle.pendingFrameCount == 0, "restored title drains corroborated pending frames")
expect(hiddenTitle.chatGeneration == retainedGeneration, "same-chat recovery preserves timeline generation")

// A message seen in two obscured frames is recovered only with two confirmed anchors.
var recovery = LiveChatScenePipeline()
let anchors = chatScreen(mine: 1, theirs: 2)
for frame in 0..<3 {
    recovery.detect(ChatSceneDetector.probeEvidence(observations: anchors, rectangles: []))
    _ = recovery.ingest(anchors, at: t0.addingTimeInterval(Double(frame)))
}
let earlier = observation("之前短暂可见的合成消息", x: 0.05, y: 0.174, width: 0.34, height: 0.012)
let obscured = anchors.filter { $0.box.midY > 0.17 } + [earlier]
for frame in 0..<2 {
    recovery.detect(weakEvidence)
    _ = recovery.ingest(obscured, at: t0.addingTimeInterval(Double(frame + 3)))
}
expect(!recovery.snapshot().messages.contains { $0.text == earlier.text }, "pending content is absent from official messages")
recovery.detect(ChatSceneDetector.probeEvidence(observations: anchors, rectangles: []))
_ = recovery.ingest(anchors, at: t0.addingTimeInterval(6))
expect(recovery.snapshot().messages.contains { $0.text == earlier.text }, "two-frame stable pending message is recovered through confirmed anchors")

// Explicit non-chat immediately cancels OCR/submission/cache, with display hysteresis.
let home = weChatListScreen()
recovery.detect(weakEvidence)
_ = recovery.ingest(obscured, at: t0.addingTimeInterval(7))
expect(recovery.pendingFrameCount > 0, "pending data exists before explicit departure")
for _ in 0..<config.requiredInactiveFrames {
    recovery.detect(ChatSceneDetector.probeEvidence(observations: home.observations, rectangles: home.rectangles))
    _ = recovery.ingest(home.observations, at: t0.addingTimeInterval(8))
    expect(!recovery.shouldRunOCR && !recovery.allowsFullRecognition, "non-chat cannot submit during display hysteresis")
    expect(recovery.pendingFrameCount == 0, "explicit departure clears pending messages immediately")
}
expect(recovery.verdict == .inactive, "continuous explicit departure pauses recognition")

// Returning after a title-covered contact switch must discard the old pending content.
var changed = LiveChatScenePipeline()
for frame in 0..<3 {
    changed.detect(ChatSceneDetector.probeEvidence(observations: anchors, rectangles: []))
    _ = changed.ingest(anchors, at: t0.addingTimeInterval(Double(frame)))
}
let changedGeneration = changed.chatGeneration
changed.detect(weakEvidence)
_ = changed.ingest(obscured, at: t0.addingTimeInterval(4))
let otherContact = chatScreen(top: "联系人乙").map { item in
    LiveOCRObservation(text: item.text + "乙", confidence: item.confidence, box: item.box)
}
for frame in 0..<3 {
    changed.detect(ChatSceneDetector.probeEvidence(observations: otherContact, rectangles: []))
    _ = changed.ingest(otherContact, at: t0.addingTimeInterval(Double(frame + 5)))
}
expect(changed.chatGeneration > changedGeneration && changed.pendingFrameCount == 0, "confirmed contact change rotates generation and drops pending data")
expect(!changed.snapshot().messages.contains { $0.text == earlier.text }, "old pending message never enters another contact")
expect(changed.snapshot().messages.allSatisfy { $0.text.hasSuffix("乙") }, "new timeline contains only the new contact")

// Unmatched and oversized pending frames must never be recovered.
changed.detect(weakEvidence)
_ = changed.ingest([observation(String(repeating: "长", count: config.maximumPendingCharacters + 1),
    x: 0.05, y: 0.3, width: 0.34)], at: t0.addingTimeInterval(10))
expect(changed.pendingFrameCount == 0, "oversized pending frame is rejected whole")
let unrelated = [observation("完全无关合成页面第一行", x: 0.05, y: 0.2, width: 0.34),
                 observation("完全无关合成页面第二行", x: 0.62, y: 0.4, width: 0.32)]
for frame in 0..<2 {
    changed.detect(weakEvidence)
    _ = changed.ingest(unrelated, at: t0.addingTimeInterval(Double(frame + 11)))
}
changed.detect(ChatSceneDetector.probeEvidence(observations: otherContact, rectangles: []))
_ = changed.ingest(otherContact, at: t0.addingTimeInterval(13))
expect(!changed.snapshot().messages.contains { $0.text.contains("完全无关") }, "unmatched pending content is discarded")
changed.detect(weakEvidence)
_ = changed.ingest(unrelated, at: t0.addingTimeInterval(14))
changed.discardPendingRecognition()
expect(changed.pendingFrameCount == 0, "capture stop discards pending recognition")
changed.reset()
expect(changed.pendingFrameCount == 0 && !changed.shouldRunOCR, "new capture resets pending state and OCR permission")

// Anonymous device layout: the compact island and status clock sit above the contact.
// Neither a changing clock nor our own message counter may identify a conversation.
func deviceNavigation(counter: String, clock: String) -> [LiveOCRObservation] {
    [observation(clock, x: 0.08, y: 0.028, width: 0.14, height: 0.02),
     observation(counter, x: 0.32, y: 0.030, width: 0.04, height: 0.02),
     observation("合成联系人甲", x: 0.36, y: 0.075, width: 0.28, height: 0.025),
     observation("顶部被裁切的合成消息", x: 0.19, y: 0.12, width: 0.60, height: 0.03)]
}
let deviceBase = chatScreen().filter { $0.box.minY > 0.17 }
let deviceBefore = ChatSceneDetector.probeEvidence(observations: deviceNavigation(counter: "0", clock: "17:10") + deviceBase, rectangles: [])
let deviceAfter = ChatSceneDetector.probeEvidence(observations: deviceNavigation(counter: "5", clock: "17:11") + deviceBase, rectangles: [])
expect(deviceBefore.topBarFingerprint == deviceAfter.topBarFingerprint,
       "live island counter and clock must not change contact identity")
expect(deviceBefore.topBarFingerprint == LiveChatText.normalize("合成联系人甲"), "contact identity excludes a clipped message below navigation")
var deviceLoop = LiveChatScenePipeline()
var deviceGeneration: Int?
for frame in 0..<12 {
    let screen = deviceNavigation(counter: String(frame), clock: "17:\(10 + frame)") + deviceBase
    deviceLoop.detect(ChatSceneDetector.probeEvidence(observations: screen, rectangles: []))
    _ = deviceLoop.ingest(screen, at: t0.addingTimeInterval(Double(frame)))
    if frame == 2 { deviceGeneration = deviceLoop.chatGeneration }
}
expect(deviceLoop.chatGeneration == deviceGeneration, "island feedback never repeatedly resets the timeline")
expect(deviceLoop.snapshot().messages.count == 5, "island feedback leaves live messages accumulated, including text directly below navigation")

let noNavigationProbe = ChatSceneDetector.probeEvidence(observations: deviceBase, rectangles: [])
expect(noNavigationProbe.topBarFingerprint == nil, "cheap probe can miss the contact while recognizing messages")
let accurateRefinement = ChatSceneDetector.refining(noNavigationProbe,
    with: deviceNavigation(counter: "0", clock: "17:10") + deviceBase)
expect(accurateRefinement.topBarFingerprint == deviceBefore.topBarFingerprint && accurateRefinement.hasNavigationBar,
       "full-frame accurate OCR recovers the contact missed by the probe")

// A covered confirmed contact is recoverable by two reliable message anchors.
let overlapGeneration = deviceLoop.chatGeneration
deviceLoop.detect(noNavigationProbe)
_ = deviceLoop.ingest(deviceBase, at: t0.addingTimeInterval(20))
expect(deviceLoop.allowsFullRecognition && deviceLoop.chatGeneration == overlapGeneration,
       "reliable message overlap confirms ownership while the contact title is covered")
expect(deviceLoop.pendingFrameCount == 0, "corroborated covered messages do not remain stuck in the buffer")
deviceLoop.detect(weakEvidence)
_ = deviceLoop.ingest(coveredOther, at: t0.addingTimeInterval(21))
expect(deviceLoop.diagnostics?.recognitionHoldReason != nil && deviceLoop.diagnostics?.rawObservationCount == coveredOther.count,
       "diagnostics distinguish OCR results from ownership quarantine")

// Anonymous dark-mode device proportions: middle bubbles can resemble an input bar.
let tenBubbleLines = [
    observation("第一条长消息的开头", x: 0.21, y: 0.140, width: 0.61, height: 0.018),
    observation("第一条长消息的中间", x: 0.21, y: 0.164, width: 0.60, height: 0.018),
    observation("第一条长消息的结尾", x: 0.21, y: 0.188, width: 0.39, height: 0.018),
    observation("8月20日 星期四 01:51", x: 0.34, y: 0.243, width: 0.32, height: 0.015),
    observation("第二条完整回复的开头", x: 0.20, y: 0.281, width: 0.62, height: 0.018),
    observation("第二条完整回复的结尾", x: 0.20, y: 0.305, width: 0.62, height: 0.018),
    observation("收到啦", x: 0.17, y: 0.366, width: 0.11, height: 0.018),
    observation("别着急，慢慢来", x: 0.17, y: 0.426, width: 0.25, height: 0.018),
    observation("现在可以了", x: 0.17, y: 0.486, width: 0.20, height: 0.018),
    observation("第六条长消息的开头", x: 0.17, y: 0.547, width: 0.62, height: 0.018),
    observation("第六条长消息的结尾", x: 0.17, y: 0.571, width: 0.24, height: 0.018),
    observation("我还在外面呢", x: 0.17, y: 0.627, width: 0.24, height: 0.018),
    observation("待会再回去", x: 0.17, y: 0.687, width: 0.22, height: 0.018),
    observation("第九条长消息的开头", x: 0.17, y: 0.748, width: 0.61, height: 0.018),
    observation("第九条长消息的结尾", x: 0.17, y: 0.772, width: 0.57, height: 0.018),
    observation("最后一条回复的开头", x: 0.21, y: 0.823, width: 0.61, height: 0.018),
    observation("最后一条回复的结尾", x: 0.21, y: 0.847, width: 0.24, height: 0.018),
]
let tenBubbleScreen = [observation("合成联系人甲", x: 0.40, y: 0.074, width: 0.20)] + tenBubbleLines
let tenBubbleRectangles = [
    CGRect(x: 0.145, y: 0.534, width: 0.67, height: 0.063),
    CGRect(x: 0.11, y: 0.918, width: 0.69, height: 0.044),
]
let tenBubbleEvidence = ChatSceneDetector.probeEvidence(observations: tenBubbleScreen, rectangles: tenBubbleRectangles)
print("Ten-bubble regression: detected input top=\(tenBubbleEvidence.inputTopRatio ?? -1)")
expect(tenBubbleEvidence.inputTopRatio == 0.918, "a long message is not the bottom input bar")
var tenBubblePipeline = LiveChatScenePipeline()
for frame in 0..<4 {
    tenBubblePipeline.detect(tenBubbleEvidence)
    _ = tenBubblePipeline.ingest(tenBubbleScreen, at: t0.addingTimeInterval(Double(frame)))
}
let tenBubbleChat = tenBubblePipeline.snapshot()
expect(tenBubbleChat.messages.count == 10, "all ten text bubbles survive cropping; date is not a message")
expect(tenBubbleChat.messages.first?.text == "第一条长消息的开头第一条长消息的中间第一条长消息的结尾", "the first multiline bubble is complete")
expect(tenBubbleChat.messages.map(\.role) == [.me, .me, .other, .other, .other, .other, .other, .other, .other, .me], "real text insets identify both speakers")
expect(tenBubbleChat.unknownCount == 0, "ten unambiguous bubbles do not require manual roles")
let labeledKeyboardEvidence = ChatSceneDetector.probeEvidence(
    observations: [observation("按住 说话", x: 0.30, y: 0.60, width: 0.25)],
    rectangles: [CGRect(x: 0.11, y: 0.595, width: 0.69, height: 0.044),
                 CGRect(x: 0.23, y: 0.89, width: 0.50, height: 0.044)])
expect(labeledKeyboardEvidence.inputTopRatio == 0.60, "an explicit input control wins over a keyboard space bar")
let proseInputEvidence = ChatSceneDetector.probeEvidence(
    observations: [observation("这条消息谈到了输入方法", x: 0.17, y: 0.65, width: 0.45)],
    rectangles: tenBubbleRectangles)
expect(proseInputEvidence.inputTopRatio == 0.918, "ordinary prose mentioning input cannot move the viewport")
for title in ["动态识别测试", "确认实时聊天", "狗头军师输入法"] {
    let ownPage = ChatSceneDetector.probeEvidence(
        observations: [observation(title, x: 0.35, y: 0.074, width: 0.30)] + tenBubbleLines,
        rectangles: tenBubbleRectangles)
    expect(ChatSceneDetector.isClearlyNonChatScene(ownPage), "our own capture/review pages cannot become a contact")
    let retainedCount = tenBubblePipeline.snapshot().messages.count
    for frame in 0..<3 {
        tenBubblePipeline.detect(ownPage)
        _ = tenBubblePipeline.ingest(ownPage.isCaptureDiagnosticsPage ? [] : tenBubbleLines,
                                     at: t0.addingTimeInterval(Double(frame + 10)))
    }
    expect(!tenBubblePipeline.shouldRunOCR && tenBubblePipeline.snapshot().messages.count == retainedCount,
           "opening review holds submission without erasing the already recognized conversation")
}

// A page header plus independent fixed controls disqualifies a non-chat page,
// even when its search/comment field happens to resemble the chat input capsule.
let settingsControls = [observation("设置", x: 0.42, y: 0.06, width: 0.16),
    observation("账号与安全", x: 0.10, y: 0.22, width: 0.26),
    observation("消息通知", x: 0.10, y: 0.32, width: 0.22),
    observation("通用", x: 0.10, y: 0.42, width: 0.12)]
let falseInput = CGRect(x: 0.11, y: 0.91, width: 0.69, height: 0.04)
let settingsEvidence = ChatSceneDetector.probeEvidence(observations: settingsControls, rectangles: [falseInput])
expect(!ChatSceneDetector.isChatScene(settingsEvidence), "settings controls cannot become chat through a wide input rectangle")
expect(ChatSceneDetector.isClearlyNonChatScene(settingsEvidence), "confirmed controls stop expensive OCR before submission")
print("ChatScreenDetectionCheck passed (\(checks) assertions; pure logic only; synthetic screens; no network)")
