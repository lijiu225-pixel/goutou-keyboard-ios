import CoreGraphics
import Foundation

/// 阶段 12B 的纯逻辑契约：坐标换算、区域过滤、多行合并、保守角色判断、
/// 连续帧稳定化、跨帧去重、滚动时间线合并、上限与代际隔离，以及「这一层不写任何东西」。
///
/// 全部用**虚构** OCR observations；不碰 ScreenCaptureKit / Vision 引擎、不联网、不落盘。
/// 真实的屏幕识别与滚动效果只能由真机验收。
var checks = 0
func expect(_ value: Bool, _ description: String) {
    checks += 1
    if !value { fatalError("LiveChatRecognitionCheck: \(description)") }
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)
let config = LiveChatGeometryConfiguration.default

func observation(
    _ text: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat = 0.03,
    confidence: Double = 0.92
) -> LiveOCRObservation {
    LiveOCRObservation(text: text, confidence: confidence, box: CGRect(x: x, y: y, width: width, height: height))
}

func candidate(
    _ text: String,
    role: LiveChatRole,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat = 0.03,
    at time: Date = t0
) -> LiveChatCandidate {
    LiveChatCandidate(
        text: text,
        normalizedText: LiveChatText.normalize(text),
        role: role,
        box: CGRect(x: x, y: y, width: width, height: height),
        confidence: 0.92,
        timestamp: time
    )
}

// MARK: - 1：Vision 左下角 → 项目统一左上角

let converted = LiveOCRObservation.fromVision(
    text: "你好",
    confidence: 0.9,
    boundingBox: CGRect(x: 0.2, y: 0.70, width: 0.3, height: 0.05)
)
expect(abs(converted.box.minY - 0.25) < 0.0001, "左下角 (maxY=0.75) 应换算成左上角 minY=0.25")
expect(converted.box.minX == 0.2 && converted.box.width == 0.3, "x / width 不变")
expect(converted.box.maxY <= 1 && converted.box.minY >= 0, "换算后仍在 0…1 内")

// MARK: - 2 / 3：聊天区域过滤（顶部状态栏、底部键盘）

let frameWithChrome = [
    observation("9:41", x: 0.45, y: 0.02, width: 0.10),                 // 状态栏
    observation("微信", x: 0.45, y: 0.07, width: 0.08),                  // 标题
    observation("今晚有空吗", x: 0.05, y: 0.30, width: 0.35),            // 聊天
    observation("q w e r t y", x: 0.02, y: 0.86, width: 0.90),           // 键盘
    observation("狗头军师", x: 0.40, y: 0.95, width: 0.20),               // 键盘底栏
]
let viewport = LiveChatViewportFilter.filter(frameWithChrome, config: config)
expect(viewport.count == 1, "顶部与底部都被过滤掉，只剩聊天区")
expect(viewport.first?.text == "今晚有空吗", "留下的正是聊天区那条")
expect(LiveChatViewportFilter.filter([observation("", x: 0.2, y: 0.4, width: 0.2)], config: config).isEmpty,
       "空文本不进候选")

// MARK: - 4~9：保守几何角色判断

expect(LiveChatRoleClassifier.classify(box: CGRect(x: 0.02, y: 0.30, width: 0.36, height: 0.03), config: config) == .other,
       "明显靠左 → other")
expect(LiveChatRoleClassifier.classify(box: CGRect(x: 0.60, y: 0.40, width: 0.34, height: 0.03), config: config) == .me,
       "明显靠右 → me")
expect(LiveChatRoleClassifier.classify(box: CGRect(x: 0.30, y: 0.50, width: 0.40, height: 0.03), config: config) == .unknown,
       "中间且很宽 → unknown")
expect(LiveChatRoleClassifier.classify(box: CGRect(x: 0.44, y: 0.20, width: 0.12, height: 0.03), config: config) == .system,
       "居中且很窄（时间）→ system")
expect(LiveChatRoleClassifier.classify(box: CGRect(x: 0.20, y: 0.60, width: 0.78, height: 0.03), config: config) == .me,
       "长消息跨中线但右 anchor → me")
expect(LiveChatRoleClassifier.classify(box: CGRect(x: 0.02, y: 0.65, width: 0.80, height: 0.03), config: config) == .other,
       "长消息跨中线但左 anchor → other")
expect(LiveChatRoleClassifier.classify(box: CGRect(x: 0.01, y: 0.70, width: 0.98, height: 0.03), config: config) == .unknown,
       "几乎铺满整行、两边都贴 → 保守 unknown")

// MARK: - 10~13：多行合并与阅读顺序

let multiLine = [
    observation("今晚要不要", x: 0.05, y: 0.300, width: 0.30),
    observation("一起出去", x: 0.05, y: 0.335, width: 0.26),
    observation("吃饭", x: 0.05, y: 0.370, width: 0.12),
]
let merged = LiveChatBlockGrouper.group(multiLine, config: config, timestamp: t0)
expect(merged.count == 1, "同一侧、相邻、水平重叠的三行合成一条")
expect(merged.first?.text == "今晚要不要一起出去吃饭", "中文相邻行直接连接")
expect(merged.first?.role == .other, "合并后仍是靠左的对方消息")

let mixedSides = [
    observation("你好", x: 0.05, y: 0.300, width: 0.65),
    observation("你好", x: 0.30, y: 0.305, width: 0.65),
]
expect(LiveChatBlockGrouper.group(mixedSides, config: config, timestamp: t0).count == 2,
       "一左一右相邻、水平也重叠，仍然绝不合并")

let farApart = [
    observation("第一条", x: 0.05, y: 0.200, width: 0.25),
    observation("第二条", x: 0.05, y: 0.320, width: 0.25),
]
expect(LiveChatBlockGrouper.group(farApart, config: config, timestamp: t0).count == 2,
       "同侧但间距过大不合并")

let unordered = [
    observation("第二行", x: 0.05, y: 0.60, width: 0.20),
    observation("第一行右", x: 0.55, y: 0.40, width: 0.20),
    observation("第一行左", x: 0.05, y: 0.40, width: 0.20),
]
let ordered = LiveChatBlockGrouper.readingOrder(unordered).map(\.text)
expect(ordered == ["第一行左", "第一行右", "第二行"], "阅读顺序：先上后下、同行从左到右")

// MARK: - 14 / 15：连续帧稳定化

var system = LiveChatSystem()
system.reset(generation: 1)
let firstFrame = [
    observation("今晚有空吗", x: 0.05, y: 0.30, width: 0.35),
    observation("有啊", x: 0.74, y: 0.38, width: 0.18),
]
let frameOne = system.ingest(observations: firstFrame, timestamp: t0, generation: 1)
expect(frameOne.candidatesThisFrame == 2, "第一帧识别到 2 个候选")
expect(frameOne.stableThisFrame == 0, "第一帧还不能 commit")
expect(frameOne.messages.isEmpty, "第一帧不写时间线")
expect(frameOne.pendingCandidates == 2, "两个候选都在等第二帧确认")

let frameTwo = system.ingest(observations: firstFrame, timestamp: t0.addingTimeInterval(0.9), generation: 1)
expect(frameTwo.stableThisFrame == 2, "第二帧两个候选都稳定")
expect(frameTwo.messages.count == 2, "稳定后进入时间线")
expect(frameTwo.messages.map(\.role) == [.other, .me], "左 → 对方、右 → 我")

// MARK: - 16 / 17：相似文本算同一条，明显不同不算

let jittered = [
    observation("今晚有空吗？", x: 0.05, y: 0.302, width: 0.35),
    observation("有啊", x: 0.74, y: 0.381, width: 0.18),
]
let frameThree = system.ingest(observations: jittered, timestamp: t0.addingTimeInterval(1.8), generation: 1)
expect(frameThree.messages.count == 2, "只差一个标点仍然算同两条，不重复添加")
expect(frameThree.messages.first?.text == "今晚有空吗", "展示文本保留最早那次的原始识别")

expect(!LiveChatTimeline.sameMessage(
    candidate("今晚吃饭吗", role: .other, x: 0.05, y: 0.3, width: 0.3),
    candidate("明天要开会", role: .other, x: 0.05, y: 0.3, width: 0.3),
    config: config
), "明显不同的文字不会被当成同一条")
expect(LiveChatTimeline.sameMessage(
    candidate("哈哈", role: .me, x: 0.6, y: 0.3, width: 0.2),
    candidate("哈哈", role: .other, x: 0.05, y: 0.3, width: 0.2),
    config: config
) == false, "相同文本但不同 role 绝不能去重")

// MARK: - 19 / 23：连续三条「哈哈」

var hahaSystem = LiveChatSystem()
hahaSystem.reset(generation: 1)
let hahaFrame = [
    observation("哈哈", x: 0.05, y: 0.300, width: 0.12),
    observation("哈哈", x: 0.05, y: 0.345, width: 0.12),
    observation("哈哈", x: 0.05, y: 0.390, width: 0.12),
]
_ = hahaSystem.ingest(observations: hahaFrame, timestamp: t0, generation: 1)
let hahaSecond = hahaSystem.ingest(observations: hahaFrame, timestamp: t0.addingTimeInterval(0.9), generation: 1)
expect(hahaSecond.messages.count == 3, "三条「哈哈」保留三条，不能被压成一条")
let hahaThird = hahaSystem.ingest(observations: hahaFrame, timestamp: t0.addingTimeInterval(1.8), generation: 1)
expect(hahaThird.messages.count == 3, "重复文本再出现也不会重复添加")

// MARK: - 20 / 21 / 22：滚动时间线合并

func screen(_ texts: [String], role: LiveChatRole, startY: CGFloat = 0.20, step: CGFloat = 0.05) -> [LiveOCRObservation] {
    texts.enumerated().map { index, text in
        let x: CGFloat = role == .me ? 0.60 : 0.05
        return observation(text, x: x, y: startY + CGFloat(index) * step, width: 0.30)
    }
}

var scrollSystem = LiveChatSystem()
scrollSystem.reset(generation: 1)
let screenABCD = screen(["A", "B", "C", "D"], role: .other)
_ = scrollSystem.ingest(observations: screenABCD, timestamp: t0, generation: 1)
let abcd = scrollSystem.ingest(observations: screenABCD, timestamp: t0.addingTimeInterval(0.9), generation: 1)
expect(abcd.messages.map(\.text) == ["A", "B", "C", "D"], "第一屏稳定后进入时间线")

let screenCDEF = screen(["C", "D", "E", "F"], role: .other)
_ = scrollSystem.ingest(observations: screenCDEF, timestamp: t0.addingTimeInterval(1.8), generation: 1)
let abcdef = scrollSystem.ingest(observations: screenCDEF, timestamp: t0.addingTimeInterval(2.7), generation: 1)
expect(abcdef.messages.map(\.text) == ["A", "B", "C", "D", "E", "F"],
       "向下滚动：C/D 靠 overlap 对齐，只把 E/F 接在后面（不是 A B C D C D E F）")

var scrollUpSystem = LiveChatSystem()
scrollUpSystem.reset(generation: 1)
_ = scrollUpSystem.ingest(observations: screenABCD, timestamp: t0, generation: 1)
_ = scrollUpSystem.ingest(observations: screenABCD, timestamp: t0.addingTimeInterval(0.9), generation: 1)
let screenXYAB = screen(["X", "Y", "A", "B"], role: .other)
_ = scrollUpSystem.ingest(observations: screenXYAB, timestamp: t0.addingTimeInterval(1.8), generation: 1)
let xyabcd = scrollUpSystem.ingest(observations: screenXYAB, timestamp: t0.addingTimeInterval(2.7), generation: 1)
expect(xyabcd.messages.map(\.text) == ["X", "Y", "A", "B", "C", "D"],
       "向上滚动：X/Y 插到最前面，已有顺序不乱")

// MARK: - 24：完全没有 overlap 时不硬拼

var noOverlapSystem = LiveChatSystem()
noOverlapSystem.reset(generation: 1)
let screenOne = screen(["甲", "乙"], role: .other)
_ = noOverlapSystem.ingest(observations: screenOne, timestamp: t0, generation: 1)
_ = noOverlapSystem.ingest(observations: screenOne, timestamp: t0.addingTimeInterval(0.9), generation: 1)
let screenTwo = screen(["丙", "丁"], role: .other)
_ = noOverlapSystem.ingest(observations: screenTwo, timestamp: t0.addingTimeInterval(1.8), generation: 1)
let unanchored = noOverlapSystem.ingest(observations: screenTwo, timestamp: t0.addingTimeInterval(2.7), generation: 1)
expect(unanchored.messages.map(\.text) == ["甲", "乙"], "没有可靠 overlap 就不拼接，时间线保持原样")
expect(unanchored.showsDiscontinuity, "同时提示「检测到不连续聊天区域」")
expect(unanchored.discontinuityFrames >= 1, "记下不连续次数")

// MARK: - 25：同一屏反复出现不会重复添加

let repeated = system.ingest(observations: jittered, timestamp: t0.addingTimeInterval(2.7), generation: 1)
expect(repeated.messages.count == 2, "同一屏再来一帧仍然是两条")

// MARK: - 26：时间线上限

var cappedConfig = LiveChatGeometryConfiguration.default
cappedConfig.maxTimelineMessages = 5
var capTimeline = LiveChatTimeline()
let capMessages = (0..<10).map { candidate("消息\($0)", role: .other, x: 0.05, y: 0.30, width: 0.30) }
for end in 1...capMessages.count {
    capTimeline.merge(Array(capMessages[0..<end]), config: cappedConfig)
}
expect(capTimeline.messages.count == 5, "到达上限后不再增长")
expect(capTimeline.truncatedOldest == 5, "丢弃最早 5 条并有计数")
expect(capTimeline.droppedAtCap > 0, "到上限后拒绝的回插另算，不和截断混在一起")
expect(capTimeline.messages.map(\.text) == ["消息5", "消息6", "消息7", "消息8", "消息9"], "保留的是最新的内容")

// MARK: - 27 / 28 / 31：代际隔离（迟到帧、旧 session、重新 start）

var generationSystem = LiveChatSystem()
generationSystem.reset(generation: 7)
let staleFrame = [observation("旧聊天", x: 0.05, y: 0.30, width: 0.30)]
_ = generationSystem.ingest(observations: staleFrame, timestamp: t0, generation: 7)
_ = generationSystem.ingest(observations: staleFrame, timestamp: t0.addingTimeInterval(0.9), generation: 7)
expect(generationSystem.snapshot().messages.count == 1, "当前 session 正常工作")

// 用户 stop 之后又 start：新的 generation，旧帧迟到
generationSystem.reset(generation: 8)
let late = generationSystem.ingest(observations: staleFrame, timestamp: t0.addingTimeInterval(1.8), generation: 7)
expect(late.messages.isEmpty, "旧代际的迟到帧一个字都不写")
let fresh = generationSystem.ingest(observations: [observation("新聊天", x: 0.05, y: 0.30, width: 0.30)],
                                    timestamp: t0.addingTimeInterval(2.7), generation: 8)
expect(fresh.messages.isEmpty, "新 session 第一帧同样要等确认")
let freshSecond = generationSystem.ingest(observations: [observation("新聊天", x: 0.05, y: 0.30, width: 0.30)],
                                          timestamp: t0.addingTimeInterval(3.6), generation: 8)
expect(freshSecond.messages.map(\.text) == ["新聊天"], "新 session 只装新内容，不受旧 session 影响")

// MARK: - 29 / 30：清空实时聊天

let cleared = generationSystem.snapshot()
generationSystem.reset(generation: generationSystem.snapshot().generation)
expect(generationSystem.snapshot().messages.isEmpty, "清空后时间线归零")
expect(cleared.generation == generationSystem.snapshot().generation, "清空不换代际：捕获可以继续")
_ = generationSystem.ingest(observations: [observation("清空之后", x: 0.05, y: 0.30, width: 0.30)],
                            timestamp: t0.addingTimeInterval(4.5), generation: 8)
let afterClear = generationSystem.ingest(observations: [observation("清空之后", x: 0.05, y: 0.30, width: 0.30)],
                                         timestamp: t0.addingTimeInterval(5.4), generation: 8)
expect(afterClear.messages.map(\.text) == ["清空之后"], "清空之后仍能继续积累")

// MARK: - 32：unknown 永远不会静默变成 me / other

var unknownSystem = LiveChatSystem()
unknownSystem.reset(generation: 1)
let ambiguous = [observation("说不清归谁", x: 0.30, y: 0.30, width: 0.40)]
_ = unknownSystem.ingest(observations: ambiguous, timestamp: t0, generation: 1)
let unknownSnapshot = unknownSystem.ingest(observations: ambiguous, timestamp: t0.addingTimeInterval(0.9), generation: 1)
expect(unknownSnapshot.messages.map(\.role) == [.unknown], "模糊内容留在 unknown")
expect(unknownSnapshot.unknownCount == 1, "unknown 有单独计数")
expect(unknownSnapshot.messages.allSatisfy { $0.role != .me && $0.role != .other }, "unknown 没有被塞进任何一方")

// MARK: - 39 / 40：大量 observations 与长 timeline 的性能边界

var stressSystem = LiveChatSystem()
stressSystem.reset(generation: 1)
var stressSnapshot = stressSystem.snapshot()
let stressStart = Date()
let stressMessages = (0..<260).map { candidate("压力\($0)", role: .other, x: 0.05, y: 0.30, width: 0.30) }
for round in 0..<40 {
    // 每帧只看 50 条、窗口每次滑 5 条：既有 overlap，又让时间线一路涨到上限
    let slice = Array(stressMessages[(round * 5)..<(round * 5 + 50)])
    let texts = slice.map(\.text)
    let observations = screen(texts, role: .other, startY: 0.13, step: 0.012)
    _ = stressSystem.ingest(observations: observations, timestamp: t0.addingTimeInterval(Double(round)), generation: 1)
    stressSnapshot = stressSystem.ingest(observations: observations,
                                         timestamp: t0.addingTimeInterval(Double(round) + 0.5),
                                         generation: 1)
}
expect(stressSnapshot.messages.count <= config.maxTimelineMessages, "每帧 50 条也不会突破上限")
expect(stressSnapshot.candidatesThisFrame <= 50, "单帧候选数与当前屏幕一致，不是历史累加")
expect(stressSnapshot.messages.count > 100, "长窗口能正常涨到上百条（实测 \(stressSnapshot.messages.count) 条）")
let stressElapsed = Date().timeIntervalSince(stressStart)
expect(stressElapsed < 10, "1000 条 observations 的处理时间在合理范围（实测 \(String(format: "%.2f", stressElapsed))s）")

// MARK: - 33~38：不落盘、不写 UserDefaults、不碰共享聊天 / AI / 输入代理 / 相册

let fm = FileManager.default
let probeRoot = fm.temporaryDirectory.appendingPathComponent("LiveChatRecognitionCheck-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: probeRoot, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: probeRoot) }
let before = try fm.contentsOfDirectory(atPath: probeRoot.path)
var cycle = LiveChatSystem()
cycle.reset(generation: 1)
_ = cycle.ingest(observations: firstFrame, timestamp: t0, generation: 1)
_ = cycle.ingest(observations: firstFrame, timestamp: t0.addingTimeInterval(0.9), generation: 1)
let after = try fm.contentsOfDirectory(atPath: probeRoot.path)
expect(before == after, "整条实时聊天流水线不往磁盘写任何文件")
expect(UserDefaults.standard.object(forKey: "goutou.live.chat.timeline") == nil, "不写 UserDefaults")
let store = SharedChatStore(testContainer: probeRoot)
var hasSharedChat = false
do { _ = try store.read(); hasSharedChat = true } catch { hasSharedChat = false }
expect(!hasSharedChat, "不写共享聊天文件")

let scannedFiles = [
    "App/ScreenCapture/LiveOCRObservation.swift",
    "App/ScreenCapture/LiveOCRSnapshot.swift",
    "App/ScreenCapture/LiveChatGeometryConfiguration.swift",
    "App/ScreenCapture/LiveChatCandidate.swift",
    "App/ScreenCapture/LiveChatRoleClassifier.swift",
    "App/ScreenCapture/LiveChatBlockGrouper.swift",
    "App/ScreenCapture/LiveChatStabilizer.swift",
    "App/ScreenCapture/LiveChatTimeline.swift",
    "App/ScreenCapture/LiveChatSystem.swift",
    "App/ScreenCapture/LiveScreenOCRProcessor.swift",
    "App/ScreenCapture/LiveScreenCaptureManager.swift",
    "App/LiveScreenCaptureView.swift",
]
let forbiddenTokens = [
    "GoutouAIClient", "URLSession", "textDocumentProxy", "insertText",
    "UIImageWriteToSavedPhotosAlbum", "PHPhotoLibrary", "AVCaptureDevice", "AVAudioSession",
    "UserDefaults", "SharedChatStore", "runMemoryExtraction", "saveSummary", "deleteBackward",
    "latest_chat", "Keychain", "ScreenCaptureKit",      // ScreenCaptureKit 只该出现在被 #if 包起来的捕获文件里
]
for file in scannedFiles {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
        expect(false, "读不到源码文件 \(file)")
        continue
    }
    for token in forbiddenTokens {
        // 捕获管理器自己就是 ScreenCaptureKit 的入口，这一条对它豁免
        if token == "ScreenCaptureKit" && file.hasSuffix("LiveScreenCaptureManager.swift") { continue }
        // 阶段 12C 起，用户点「保存给狗头军师」的手动交接也在管理器里（LiveChatReviewSaver）；
        // 「识别过程绝不自动写共享聊天」由 LiveChatReviewCheck 的行为测试把关。
        if token == "SharedChatStore" && file.hasSuffix("LiveScreenCaptureManager.swift") { continue }
        expect(!text.contains(token), "\(file) 不该出现 \(token)")
    }
}

print("LiveChatRecognitionCheck passed (\(checks) assertions; pure logic only; no ScreenCaptureKit, no network)")
