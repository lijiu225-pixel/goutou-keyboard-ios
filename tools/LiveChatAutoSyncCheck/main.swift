import CoreGraphics
import Foundation

/// 阶段 12D 的纯逻辑契约：用户主动开启的自动同步（授权、资格、fingerprint、debounce、
/// 最低写入间隔、并发保护、代际隔离、人工保存防覆盖）。
///
/// 时间全部由测试推进（不真的等 1.5 秒），写盘用临时目录里的真实 SharedChatStore。
/// 全部虚构文本；不碰屏幕捕获、不联网、不调 AI、不碰键盘。
var checks = 0
func expect(_ value: Bool, _ description: String) {
    checks += 1
    if !value { fatalError("LiveChatAutoSyncCheck: \(description)") }
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)
let config = LiveChatAutoSyncConfiguration.default

func candidate(_ text: String, role: LiveChatRole, at time: Date = t0) -> LiveChatCandidate {
    LiveChatCandidate(
        text: text,
        normalizedText: LiveChatText.normalize(text),
        role: role,
        box: CGRect(x: 0.05, y: 0.3, width: 0.3, height: 0.03),
        confidence: 0.9,
        timestamp: time
    )
}

/// 测试用小执行器：忠实照协调器的做法执行 effect（schedule 只记下来，时间由测试推进）。
struct AutoSyncHarness {
    let store: SharedChatStore
    var config = LiveChatAutoSyncConfiguration.default
    var session = LiveChatAutoSyncSession()
    var scheduledDeadline: Date?
    var saves = 0
    var lastSaveAt: Date?
    var forcedError: String?

    init(store: SharedChatStore) {
        self.store = store
    }

    var readBack: [GoutouChatClipboardMessage] {
        (try? store.read().messages) ?? []
    }

    mutating func resetForNewSession(generation: Int) {
        apply(session.resetForNewSession(generation: generation), now: t0)
    }

    mutating func setEnabled(_ enabled: Bool, messages: [LiveChatCandidate], now: Date) {
        apply(session.setEnabled(enabled, messages: messages, now: now, config: config), now: now)
    }

    mutating func noteTimeline(_ messages: [LiveChatCandidate], now: Date) {
        apply(session.noteTimeline(messages: messages, now: now, config: config), now: now)
    }

    mutating func stop(now: Date) {
        apply(session.stop(), now: now)
    }

    mutating func clearLiveChat(now: Date) {
        apply(session.clearLiveChat(), now: now)
    }

    mutating func manualSaveSucceeded(now: Date) {
        apply(session.noteManualSaveSucceeded(), now: now)
    }

    /// 时间推进到 now：排队的时刻到了就触发一次 fireDue。
    mutating func advance(to now: Date) {
        guard let deadline = scheduledDeadline, now >= deadline else { return }
        scheduledDeadline = nil
        apply(session.fireDue(now: now, config: config), now: now)
    }

    private mutating func apply(_ effect: LiveChatAutoSyncEffect, now: Date) {
        switch effect {
        case .idle:
            break
        case .cancelScheduled:
            scheduledDeadline = nil
        case .schedule(let deadline):
            scheduledDeadline = deadline
        case .save(let snapshot):
            saves += 1
            lastSaveAt = now
            if let forcedError {
                apply(session.saveFinished(fingerprint: snapshot.fingerprint,
                                           result: .failure(LiveChatAutoSyncFailure(forcedError)),
                                           at: now), now: now)
                return
            }
            do {
                // updatedAt 用这次「真正写入」的时刻（生产环境就是 Date()）
                let saved = try store.save(GoutouChatClipboardPayload(messages: snapshot.messages), updatedAt: now)
                let result = LiveChatAutoSyncSnapshot(
                    messages: saved.messages,
                    fingerprint: snapshot.fingerprint,
                    generation: snapshot.generation
                )
                apply(session.saveFinished(fingerprint: snapshot.fingerprint, result: .success(result), at: now), now: now)
            } catch {
                apply(session.saveFinished(fingerprint: snapshot.fingerprint,
                                           result: .failure(LiveChatAutoSyncFailure("写入共享聊天失败")),
                                           at: now), now: now)
            }
        }
    }
}

let fm = FileManager.default
func makeRoot(_ tag: String) throws -> URL {
    let url = fm.temporaryDirectory.appendingPathComponent("LiveChatAutoSyncCheck-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let root = try makeRoot("main")
defer { try? fm.removeItem(at: root) }
let store = SharedChatStore(testContainer: root)
let chatFile = root
    .appendingPathComponent(SharedConstants.chatDirectory)
    .appendingPathComponent(SharedConstants.latestChatFilename)

// MARK: - 1 / 2 / 34：默认关闭，新 session 也要重新授权

var harness = AutoSyncHarness(store: store)
expect(harness.session.state == .disabled, "1. 默认就是关闭")
expect(!harness.session.enabled, "1b. 开关默认关")
harness.resetForNewSession(generation: 1)
expect(harness.session.state == .disabled, "2/34. 开始捕获之后仍然是关闭")

let chat = [candidate("今晚有空吗", role: .other), candidate("有啊", role: .me)]
harness.noteTimeline(chat, now: t0)
expect(harness.saves == 0, "2b. 没授权前不会写")
expect(!fm.fileExists(atPath: chatFile.path), "2c. 没授权前不会写文件")

// MARK: - 3 / 4 / 5 / 12 / 16：用户主动开启后才同步，且要有一条有效消息

harness.setEnabled(true, messages: [], now: t0)
expect(harness.session.state == .waitingForChat, "4. 没有聊天时是 waitingForChat")
expect(harness.saves == 0, "4b. 不会写空 payload")

harness.noteTimeline([candidate("21:30", role: .system)], now: t0)
expect(harness.session.state == .waitingForChat, "5. 只有 system 时同样不保存")
expect(harness.saves == 0, "5b. system 不会被当成聊天写进去")

harness.noteTimeline(chat, now: t0)
expect(harness.session.state == .scheduled, "16. 第一次有效时间线产生一次 scheduled")
expect(harness.scheduledDeadline == t0.addingTimeInterval(config.debounceInterval), "16b. 排的是 debounce 之后")
expect(harness.saves == 0, "16c. debounce 期间先不写")

harness.advance(to: t0.addingTimeInterval(config.debounceInterval))
expect(harness.saves == 1, "3/10. 授权 + 有 me/other 才会真正写一次")
expect(harness.session.state == .synced(messageCount: 2, at: t0.addingTimeInterval(config.debounceInterval)),
       "23. 成功后进入 synced")
expect(harness.session.lastMessageCount == 2, "25. 记下成功条数")
expect(harness.session.lastSyncAt == t0.addingTimeInterval(config.debounceInterval), "24. 记下成功时间")
expect(harness.session.lastSuccessfulFingerprint != nil, "23b. 记下成功指纹")

// MARK: - 11 / 12 / 13 / 14 / 45~50：正式 payload 的样子

expect(harness.readBack.map(\.text) == ["今晚有空吗", "有啊"], "12/13. 顺序与正文保持不变")
expect(harness.readBack.map(\.role) == [.other, .me], "14. 角色保持不变")
expect(harness.readBack.allSatisfy { $0.role == .me || $0.role == .other }, "46. 正式 payload 只有 me / other")

let rawJSON = (try? String(contentsOf: chatFile, encoding: .utf8)) ?? ""
expect(rawJSON.contains("\"format\"") && rawJSON.contains("goutou-chat"), "45. 继续用现有 format")
expect(rawJSON.contains("\"version\"") && rawJSON.contains("\"messages\""), "45b. 契约字段没变")
for leaked in ["boundingBox", "confidence", "fingerprint", "generation", "geometry", "unknown", "system"] {
    expect(!rawJSON.contains(leaked), "47~50. 正式 JSON 里不该出现 \(leaked)")
}
let savedSnapshot = try store.read()
expect(abs(savedSnapshot.updatedAt.timeIntervalSince(t0.addingTimeInterval(config.debounceInterval))) < 0.001,
       "15. updatedAt 用实际写入时刻")

// MARK: - 18 / 19 / 20 / 57：相同内容不重复写；内容变了才写

for tick in 1...20 {
    harness.noteTimeline(chat, now: t0.addingTimeInterval(10 + Double(tick) * 0.5))
    harness.advance(to: t0.addingTimeInterval(10 + Double(tick) * 0.5))
}
expect(harness.saves == 1, "18/57. 内容不变时 20 次更新也不会重复写盘")

let textChanged = [candidate("今晚有空吗", role: .other), candidate("有啊，我七点有空", role: .me)]
harness.noteTimeline(textChanged, now: t0.addingTimeInterval(30))
expect(harness.session.state == .scheduled, "19. 条数相同但正文变化会重新同步")
harness.advance(to: t0.addingTimeInterval(31))
expect(harness.saves == 2, "19b. 真的写了第二次")

let roleChanged = [candidate("今晚有空吗", role: .me), candidate("有啊，我七点有空", role: .other)]
harness.noteTimeline(roleChanged, now: t0.addingTimeInterval(40))
expect(harness.session.state == .scheduled, "20. 正文相同但角色变化也会重新同步")
harness.advance(to: t0.addingTimeInterval(41))
expect(harness.saves == 3, "20b. 真的写了第三次")

// MARK: - 6~9 / 11：unknown 拦住整次同步，system 丢在外

harness.noteTimeline(chat + [candidate("说不清是谁说的", role: .unknown)], now: t0.addingTimeInterval(50))
expect(harness.session.state == .blockedUnknown(count: 1), "6. 有 unknown 就整次拦住")
expect(harness.scheduledDeadline == nil, "6b. 排队的也取消掉")
expect(harness.readBack.map(\.text) == ["今晚有空吗", "有啊，我七点有空"], "9. 不会偷偷丢掉 unknown 只保存残缺聊天")
let blockedFingerprint = harness.session.lastSuccessfulFingerprint
harness.advance(to: t0.addingTimeInterval(60))
expect(harness.readBack.contains { $0.text.contains("说不清") } == false, "7/8. unknown 不会被猜成 me / other 写进去")
expect(harness.session.lastSuccessfulFingerprint == blockedFingerprint, "10b. 被拦住时成功指纹不变")

harness.noteTimeline(chat + [candidate("21:30", role: .system)], now: t0.addingTimeInterval(70))
expect(harness.session.state != .blockedUnknown(count: 1), "11b. unknown 消失后可以恢复")
harness.advance(to: t0.addingTimeInterval(72))
expect(harness.saves >= 4, "11c. 恢复之后又能同步")
expect(harness.readBack.map(\.text) == ["今晚有空吗", "有啊"], "11. system 被排除在正式 payload 之外")

// MARK: - 17：debounce 窗口内连续变化只写最后一份

let burstRoot = try makeRoot("burst")
defer { try? fm.removeItem(at: burstRoot) }
var burst = AutoSyncHarness(store: SharedChatStore(testContainer: burstRoot))
burst.resetForNewSession(generation: 1)
burst.setEnabled(true, messages: [], now: t0)
burst.noteTimeline([candidate("A", role: .me)], now: t0)
burst.noteTimeline([candidate("A", role: .me), candidate("B", role: .other)], now: t0.addingTimeInterval(0.4))
burst.noteTimeline([candidate("A", role: .me), candidate("B", role: .other), candidate("C", role: .other)],
                   now: t0.addingTimeInterval(0.8))
expect(burst.saves == 0, "17. 连续变化期间一次都不写")
burst.advance(to: t0.addingTimeInterval(0.8 + config.debounceInterval))
expect(burst.saves == 1, "17b. 稳定之后只写一次")
expect(burst.readBack.map(\.text) == ["A", "B", "C"], "17c. 写的是最后那一份")

// MARK: - 21 / 22：并发写保护

var busy = AutoSyncHarness(store: store)
busy.resetForNewSession(generation: 1)
busy.setEnabled(true, messages: [], now: t0.addingTimeInterval(100))
let firstBatch = [candidate("第一批", role: .me)]
busy.noteTimeline(firstBatch, now: t0.addingTimeInterval(100))
let firstEffect = busy.session.fireDue(now: t0.addingTimeInterval(102), config: config)
guard case .save = firstEffect else { fatalError("LiveChatAutoSyncCheck: 21. 第一次应当直接进入保存") }
expect(busy.session.isSaving, "21b. 有一个写操作在飞")
let secondEffect = busy.session.fireDue(now: t0.addingTimeInterval(104), config: config)
expect(secondEffect == .idle, "21. 在飞的时候不会并发第二个 save")

let laterBatch = [candidate("第二批", role: .me)]
let pendingEffect = busy.session.noteTimeline(laterBatch, now: t0.addingTimeInterval(105), config: config)
expect(pendingEffect != .idle, "22b. 在飞期间的更新会被排上队")
let finishFirst = busy.session.saveFinished(
    fingerprint: busy.session.lastAttemptFingerprint ?? "",
    result: .failure(LiveChatAutoSyncFailure("先失败（只是为了让在飞状态结束）")),
    at: t0.addingTimeInterval(106)
)
expect(finishFirst != .idle, "22. 第一份结束后会按最新那份继续排")

// MARK: - 26~29：失败处理与旧聊天保护

let failRoot = try makeRoot("fail")
defer { try? fm.removeItem(at: failRoot) }
let failStore = SharedChatStore(testContainer: failRoot)
try failStore.save(GoutouChatClipboardPayload(messages: [GoutouChatClipboardMessage(role: .me, text: "旧的一份")]),
                   updatedAt: t0)
var failing = AutoSyncHarness(store: failStore)
failing.forcedError = "写入共享聊天失败"
failing.resetForNewSession(generation: 1)
failing.setEnabled(true, messages: [], now: t0)
failing.noteTimeline([candidate("新的内容", role: .me)], now: t0)
failing.advance(to: t0.addingTimeInterval(2))
expect(failing.saves == 1, "26b. 真的尝试了一次")
if case .failed = failing.session.state { expect(true, "26. 失败进入 failed") } else { expect(false, "26. 失败进入 failed") }
expect((try? failStore.read().messages.map(\.text)) == ["旧的一份"], "29. 自动保存失败后旧聊天仍然可读")

for tick in 1...5 {
    failing.noteTimeline([candidate("新的内容", role: .me)], now: t0.addingTimeInterval(10 + Double(tick)))
}
expect(failing.saves == 1, "27. 相同失败内容不会每个 tick 疯狂重试")
failing.noteTimeline([candidate("换了内容", role: .me)], now: t0.addingTimeInterval(20))
expect(failing.session.state == .scheduled, "28. 内容变化后允许再次尝试")

// MARK: - 30~33 / 37~39：关闭、停止、清空

var lifecycle = AutoSyncHarness(store: store)
lifecycle.resetForNewSession(generation: 1)
lifecycle.setEnabled(true, messages: [], now: t0.addingTimeInterval(200))
lifecycle.noteTimeline([candidate("挂着的", role: .me)], now: t0.addingTimeInterval(200))
expect(lifecycle.scheduledDeadline != nil, "30b. 先有一个排队中的写入")
lifecycle.setEnabled(false, messages: [], now: t0.addingTimeInterval(201))
expect(lifecycle.scheduledDeadline == nil, "30. 关闭自动同步会取消排队")
lifecycle.noteTimeline([candidate("关了之后的变化", role: .me)], now: t0.addingTimeInterval(210))
expect(lifecycle.saves == 0, "31. 关闭之后时间线怎么变都不写")

lifecycle.setEnabled(true, messages: [], now: t0.addingTimeInterval(220))
lifecycle.noteTimeline([candidate("又要写的", role: .me)], now: t0.addingTimeInterval(220))
expect(lifecycle.scheduledDeadline != nil, "32b. 重新开启后可以排队")
lifecycle.stop(now: t0.addingTimeInterval(221))
expect(lifecycle.scheduledDeadline == nil, "32. Stop 会取消 pending")
expect(lifecycle.session.state == .disabled, "33. Stop 之后开关回到关闭")
expect((try? store.read().messages.count) != nil, "32c. Stop 不会删除已经共享出去的聊天")

lifecycle.resetForNewSession(generation: 2)
expect(lifecycle.session.state == .disabled, "34b. 新的 capture session 默认关闭")
expect(lifecycle.session.lastSuccessfulFingerprint == nil, "26b2. 新 session 不带旧 fingerprint")

var clearing = AutoSyncHarness(store: store)
clearing.resetForNewSession(generation: 1)
clearing.setEnabled(true, messages: [], now: t0.addingTimeInterval(300))
clearing.noteTimeline([candidate("排队中的", role: .me)], now: t0.addingTimeInterval(300))
let sharedBeforeClear = (try? store.read().messages.map(\.text)) ?? []
clearing.clearLiveChat(now: t0.addingTimeInterval(301))
expect(clearing.scheduledDeadline == nil, "37. 清空实时聊天会取消 pending")
expect((try? store.read().messages.map(\.text)) == sharedBeforeClear, "38. 清空实时聊天不删除已共享聊天")
clearing.noteTimeline([candidate("清空之后的新聊天", role: .me)], now: t0.addingTimeInterval(310))
expect(clearing.session.state == .scheduled, "39. 仍然开着的话，新的时间线会重新同步")

// MARK: - 35 / 36：代际隔离

var generations = AutoSyncHarness(store: store)
generations.resetForNewSession(generation: 1)
generations.setEnabled(true, messages: [], now: t0.addingTimeInterval(400))
generations.noteTimeline([candidate("旧 session", role: .me)], now: t0.addingTimeInterval(400))
let staleFingerprint = generations.session.pending?.snapshot.fingerprint ?? "none"
generations.resetForNewSession(generation: 2)
expect(generations.scheduledDeadline == nil, "35. 旧 generation 的排队任务不能带进新 session")
let staleResult = generations.session.saveFinished(fingerprint: staleFingerprint, result: .success(
    LiveChatAutoSyncSnapshot(messages: [], fingerprint: staleFingerprint, generation: 1)
), at: t0.addingTimeInterval(410))
expect(staleResult == .idle, "36. 旧任务的迟到回报不会污染新 session")
expect(generations.session.lastSyncAt == nil, "36b. 新 session 的统计保持干净")

// MARK: - 40~44：人工确认保存的优先级

var manual = AutoSyncHarness(store: store)
manual.resetForNewSession(generation: 1)
manual.setEnabled(true, messages: [], now: t0.addingTimeInterval(500))
manual.noteTimeline([candidate("自动识别的内容", role: .me)], now: t0.addingTimeInterval(500))
expect(manual.scheduledDeadline != nil, "41b. 先有排队中的自动同步")
manual.manualSaveSucceeded(now: t0.addingTimeInterval(501))
expect(manual.session.state == .pausedAfterManualSave, "40. 人工保存成功后进入 pausedAfterManualSave")
expect(manual.scheduledDeadline == nil, "41. 人工保存成功会取消 pending 自动同步")

for tick in 1...5 {
    manual.noteTimeline([candidate("人工修正之后时间线又变了\(tick)", role: .other)], now: t0.addingTimeInterval(510 + Double(tick)))
}
expect(manual.saves == 0, "42. 人工结果不会被自动同步覆盖")
expect(manual.session.state == .pausedAfterManualSave, "42b. 状态仍然是暂停")

manual.setEnabled(true, messages: [candidate("用户重新开启后的内容", role: .me)], now: t0.addingTimeInterval(520))
expect(manual.session.state == .scheduled, "43. 用户明确重新开启后自动同步才恢复")

// MARK: - 51 / 52：不写 UserDefaults、不持久化开关

expect(UserDefaults.standard.object(forKey: "goutou.live.chat.autosync") == nil, "51. 不写 UserDefaults")
expect(UserDefaults.standard.object(forKey: "goutou.live.chat.autosync.enabled") == nil, "52. 自动同步开关不持久化")

// MARK: - 16 的真实计时器版本：让协调器自己跑一遍（debounce 调成 0.05s）

let coordinatorRoot = try makeRoot("coordinator")
defer { try? fm.removeItem(at: coordinatorRoot) }
let coordinatorStore = SharedChatStore(testContainer: coordinatorRoot)
var fastConfig = LiveChatAutoSyncConfiguration.default
fastConfig.debounceInterval = 0.05
fastConfig.minimumSaveInterval = 0.05
let coordinatorQueue = DispatchQueue(label: "LiveChatAutoSyncCheck.coordinator")
let coordinator = LiveChatAutoSyncCoordinator(store: coordinatorStore, config: fastConfig, queue: coordinatorQueue)
let fired = DispatchSemaphore(value: 0)
coordinator.onStateChange = { state, _, _ in
    if case .synced = state { fired.signal() }
}
coordinatorQueue.async {
    coordinator.resetForNewSession(generation: 1)
    coordinator.setEnabled(true, messages: [])
    coordinator.noteTimeline([candidate("走真实计时器的内容", role: .me)])
}
if fired.wait(timeout: .now() + 5) == .timedOut {
    expect(false, "16d. 协调器应当在自己的 debounce 之后真的写入一次")
} else {
    expect(true, "16d. 协调器在自己的 debounce 之后真的写入一次")
}
coordinatorQueue.sync {
    expect((try? coordinatorStore.read().messages.map(\.text)) == ["走真实计时器的内容"], "16e. 协调器写进了共享聊天")
}

// MARK: - 53~56：源码级保证（不调用 AI / 键盘 Context / 输入代理 / 人物记忆）

let autoSyncFiles = [
    "App/ScreenCapture/LiveChatAutoSyncConfiguration.swift",
    "App/ScreenCapture/LiveChatAutoSyncState.swift",
    "App/ScreenCapture/LiveChatAutoSyncSession.swift",
    "App/ScreenCapture/LiveChatAutoSyncCoordinator.swift",
]
let forbiddenTokens = [
    "GoutouAIClient", "URLSession", "analyzeChat",
    "RecognizedChatAnalysis", "ActiveRecognizedChatContext",
    "textDocumentProxy", "insertText", "deleteBackward",
    "GoutouMemory", "runMemoryExtraction", "saveSummary",
    "UserDefaults", "Keychain", "AVCaptureDevice", "PHPhotoLibrary",
]
for file in autoSyncFiles {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
        expect(false, "读不到源码文件 \(file)")
        continue
    }
    for token in forbiddenTokens {
        expect(!text.contains(token), "53~56. \(file) 不该出现 \(token)")
    }
}

print("LiveChatAutoSyncCheck passed (\(checks) assertions; temporary container only; injected clock; no network)")
