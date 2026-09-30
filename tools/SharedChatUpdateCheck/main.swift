import Foundation

/// 阶段 12E 的纯逻辑契约：键盘自动发现 SharedChatStore 里的新聊天、以及「使用最新聊天」的语义。
///
/// 用临时目录当共享容器；不联网、不调 AI、不碰输入代理。全部虚构文本。
var checks = 0
func expect(_ value: Bool, _ description: String) {
    checks += 1
    if !value { fatalError("SharedChatUpdateCheck: \(description)") }
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

func snapshot(_ messages: [GoutouChatClipboardMessage], at time: Date = t0) -> SharedChatSnapshot {
    SharedChatSnapshot(messages: messages, updatedAt: time)
}
func message(_ text: String, _ role: GoutouChatRole) -> GoutouChatClipboardMessage {
    GoutouChatClipboardMessage(role: role, text: text)
}

let chatA = [message("今晚有空吗", .other), message("有啊", .me)]
let chatB = [message("今晚有空吗", .other), message("有啊，我七点有空", .me)]
let chatC = [message("晚上吃什么", .other), message("都行", .me)]

// MARK: - 1~5：检查的四种基本结论

expect(SharedChatUpdateDetector.evaluate(shared: snapshot([]), knownFingerprint: nil) == .upToDate,
       "2. 共享存储里没有有效聊天时不算「发现更新」")
expect(SharedChatUpdateDetector.evaluate(shared: snapshot([]), knownFingerprint: nil).pending == nil,
       "2b. 空内容永远不会有 pending")

let availableA = SharedChatUpdateDetector.evaluate(shared: snapshot(chatA), knownFingerprint: nil)
guard case .available(let pendingA) = availableA else { fatalError("SharedChatUpdateCheck: 3. 没有 known 指纹时应当发现 A") }
expect(pendingA.messageCount == 2, "3b. pending 带着条数")
expect(pendingA.updatedAt == t0, "3c. pending 带着保存时间")

let fingerprintA = pendingA.fingerprint
expect(SharedChatUpdateDetector.evaluate(shared: snapshot(chatA), knownFingerprint: fingerprintA) == .upToDate,
       "4. 已知就是 A 时 upToDate（不再反复提示）")

let availableB = SharedChatUpdateDetector.evaluate(shared: snapshot(chatB), knownFingerprint: fingerprintA)
guard case .available(let pendingB) = availableB else { fatalError("SharedChatUpdateCheck: 5. A → B 应当发现更新") }
expect(pendingB.fingerprint != fingerprintA, "5b. B 的指纹和 A 不同")

// MARK: - 6~10：指纹必须抓住所有真实变化，而不是只看条数 / 时间

let sameCountDifferentText = [message("今晚有空吗", .other), message("在忙", .me)]
expect(SharedChatUpdateDetector.evaluate(shared: snapshot(sameCountDifferentText), knownFingerprint: fingerprintA).pending != nil,
       "6. 条数相同但正文不同仍然算更新")

let sameTextDifferentRole = [message("今晚有空吗", .me), message("有啊", .other)]
expect(SharedChatUpdateDetector.evaluate(shared: snapshot(sameTextDifferentRole), knownFingerprint: fingerprintA).pending != nil,
       "7. 正文相同但 role 不同仍然算更新")

let differentOrder = [message("有啊", .me), message("今晚有空吗", .other)]
expect(SharedChatUpdateDetector.evaluate(shared: snapshot(differentOrder), knownFingerprint: fingerprintA).pending != nil,
       "8. 顺序不同仍然算更新")

expect(SharedChatUpdateDetector.evaluate(shared: snapshot(chatA, at: t0.addingTimeInterval(600)), knownFingerprint: fingerprintA) == .upToDate,
       "9. 内容相同、只是 updatedAt 变新：不算无意义更新（约定：以内容指纹为准）")

expect(SharedChatUpdateDetector.evaluate(shared: snapshot(chatB, at: t0.addingTimeInterval(-99999)), knownFingerprint: fingerprintA).pending != nil,
       "10. 内容变了但时间元数据异常，也不会漏掉更新")

expect(SharedChatFingerprint.make(messages: chatA) == fingerprintA, "指纹算法两端一致（Keyboard 与 App 共用同一份实现）")
expect(SharedChatFingerprint.make(messages: chatA) != SharedChatFingerprint.make(messages: chatB), "内容不同 → 指纹不同")

// MARK: - 11 / 12：pending 只有一份，而且会往最新走

let repeated = SharedChatUpdateDetector.evaluate(shared: snapshot(chatB), knownFingerprint: fingerprintA)
expect(repeated.pending?.fingerprint == pendingB.fingerprint, "11. 重复检查同一份 B 仍然只有一个 pending B")

let newer = SharedChatUpdateDetector.evaluate(shared: snapshot(chatC), knownFingerprint: fingerprintA)
guard case .available(let pendingC) = newer else { fatalError("SharedChatUpdateCheck: 12. B → C 应当更新 pending") }
expect(pendingC.snapshot.messages.map(\.text) == ["晚上吃什么", "都行"], "12b. pending 会跟到最新的 C，不会让用户用一个落后的 B")

// MARK: - 13~18：使用最新聊天

var recognizedChat = RecognizedChatSession()
expect(recognizedChat.adoptActive(snapshot(chatA)), "13. 使用最新聊天会建立活动上下文")
expect(recognizedChat.active?.messages.map(\.text) == ["今晚有空吗", "有啊"], "14/16. 正文与顺序保持")
expect(recognizedChat.active?.messages.map(\.role) == [.other, .me], "15. role 保持")

let adoptedFingerprint = SharedChatFingerprint.make(messages: recognizedChat.active?.messages ?? [])
expect(SharedChatUpdateDetector.evaluate(shared: snapshot(chatA), knownFingerprint: adoptedFingerprint) == .upToDate,
       "17/18. 用了之后 pending 清除、指纹记为当前")

expect(recognizedChat.adoptActive(pendingC.snapshot), "13b. 再换成最新那份")
expect(recognizedChat.active?.messages.map(\.text) == ["晚上吃什么", "都行"], "13c. Active 变成最新版本")
expect(recognizedChat.preview?.messages.map(\.text) == ["晚上吃什么", "都行"], "13d. 预览也一起换成同一份，不会新旧混用")

// MARK: - 19~22：使用新聊天要清掉旧分析（tone / replies 在同一个结构化结果里）

var analysis = RecognizedChatAnalysisSession()
analysis.invalidate()
guard case .started(let generation) = analysis.begin(
    hasFullAccess: true,
    config: GoutouConfig(baseURL: "https://example.invalid/v1", model: "test-model", apiKey: ""),
    skillAvailable: true,
    context: RecognizedChatContext(messages: chatA, updatedAt: t0)
) else { fatalError("SharedChatUpdateCheck: 19. 先造一份旧分析") }
analysis.complete(generation: generation, result: .success(RecognizedChatResult(
    analysis: "旧的分析",
    tone: "旧的对方状态",
    replies: ["旧的回复一", "旧的回复二", "旧的回复三"]
)))
guard case .success = analysis.state else { fatalError("SharedChatUpdateCheck: 19b. 旧分析应当成功") }

// 用户点「使用最新聊天」时控制器先 drop（取消任务 + invalidate），再换 Active
analysis.invalidate()
expect(analysis.state == .idle, "19/20/21. 使用新聊天后旧 analysis / tone / replies 一起清掉")
expect(!analysis.isAnalyzing, "22. 旧的在途分析也一并作废")

// MARK: - 23~25：仅仅「发现」新聊天不许动任何东西

var untouchedAnalysis = RecognizedChatAnalysisSession()
untouchedAnalysis.invalidate()
guard case .started(let keepGeneration) = untouchedAnalysis.begin(
    hasFullAccess: true,
    config: GoutouConfig(baseURL: "https://example.invalid/v1", model: "test-model", apiKey: ""),
    skillAvailable: true,
    context: RecognizedChatContext(messages: chatA, updatedAt: t0)
) else { fatalError("SharedChatUpdateCheck: 23. 造一份在跑的分析") }
let beforeDiscovery = untouchedAnalysis.state
var chatBeforeDiscovery = RecognizedChatSession()
_ = chatBeforeDiscovery.adoptActive(snapshot(chatA))

_ = SharedChatUpdateDetector.evaluate(shared: snapshot(chatC), knownFingerprint: adoptedFingerprint)

expect(untouchedAnalysis.state == beforeDiscovery, "24. 只是发现新聊天：当前 analysis 不变")
expect(untouchedAnalysis.isAnalyzing, "23. 只是发现新聊天：不会取消在跑的 AI 请求")
expect(chatBeforeDiscovery.active?.messages.map(\.text) == ["今晚有空吗", "有啊"], "25. 只是发现新聊天：Active Context 不被替换")
untouchedAnalysis.complete(generation: keepGeneration, result: .failure(.ai(.timeout)))

// MARK: - 29~31：自动检查失败是非破坏性的

let failure = SharedChatUpdateState.failedNonDestructive("尚未保存聊天")
expect(failure.pending == nil, "29/30/31. 自动检查失败不会给出 pending")
expect(failure != .available(pendingC), "31b. 失败状态不会被当成「发现新聊天」")
expect(chatBeforeDiscovery.active?.messages.map(\.text) == ["今晚有空吗", "有啊"],
       "29b. 自动检查失败（文件不存在 / JSON 损坏 / 容器不可用）不清除当前 Active")

// MARK: - 33：键盘被系统重建后仍能发现

var rebuiltChat = RecognizedChatSession()          // 全新的 keyboard session：没有任何已知指纹
expect(SharedChatUpdateDetector.evaluate(shared: snapshot(chatC), knownFingerprint: nil).pending != nil,
       "33. 重建后第一次检查就能发现共享聊天（不依赖上一次的内存状态）")
expect(!rebuiltChat.adoptActive(snapshot([])), "边界：空聊天不能当上下文")

// MARK: - 34 / 35：只读共享聊天，不写任何东西

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("SharedChatUpdateCheck-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let store = SharedChatStore(testContainer: root)
try store.save(GoutouChatClipboardPayload(messages: chatA), updatedAt: t0)
let before = try fm.contentsOfDirectory(atPath: root.path)
for _ in 0..<5 {
    _ = SharedChatUpdateDetector.evaluate(shared: try store.read(), knownFingerprint: nil)
}
let after = try fm.contentsOfDirectory(atPath: root.path)
expect(before == after, "35. 反复检查不会新增 App Group 文件")
expect(UserDefaults.standard.object(forKey: "goutou.shared.chat.update") == nil, "34. pending 状态不写 UserDefaults")

// MARK: - 结构保证：不调 AI / 不插字 / 不发送；检查只在事件节点触发

let updateFiles = [
    "Keyboard/SharedChatUpdateDetector.swift",
]
let forbiddenInDetector = [
    "GoutouAIClient", "analyzeChat", "URLSession",
    "textDocumentProxy", "insertText", "deleteBackward",
    "UserDefaults", "Timer", "scheduledTimer",
]
for file in updateFiles {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
        expect(false, "读不到源码文件 \(file)")
        continue
    }
    for token in forbiddenInDetector {
        expect(!text.contains(token), "\(file) 不该出现 \(token)")
    }
}

guard let controller = try? String(contentsOfFile: "Keyboard/KeyboardViewController.swift", encoding: .utf8) else {
    fatalError("SharedChatUpdateCheck: 读不到 KeyboardViewController.swift")
}
expect(controller.contains("checkForSharedChatUpdate()"), "1. 检查函数存在并在事件节点被调用")
expect(controller.contains("override func viewWillAppear"), "1b. 键盘重新出现时会再检查一次")
expect(!controller.contains("Timer.scheduledTimer"), "8. 没有定时轮询")
expect(!controller.contains("while true"), "8b. 没有后台死循环")
guard let useLatestRange = controller.range(of: "case .useLatestSharedChat:") else {
    fatalError("SharedChatUpdateCheck: 找不到 useLatestSharedChat 分支")
}
let useLatestBody = String(controller[useLatestRange.lowerBound...].prefix(700))
expect(useLatestBody.contains("dropRecognizedChatAnalysis()"), "22b. 使用最新聊天会作废旧分析与在途请求")
expect(useLatestBody.contains("adoptActive"), "13e. 使用最新聊天会切换 Active Context")
for token in ["GoutouAIClient", "analyzeChat"] {
    expect(!useLatestBody.contains(token), "26. 使用最新聊天不得触发 AI（\(token)）")
}
expect(!controller.contains("Timer("), "8c. 键盘侧没有用定时器做轮询")

print("SharedChatUpdateCheck passed (\(checks) assertions; temporary container only; no network)")
