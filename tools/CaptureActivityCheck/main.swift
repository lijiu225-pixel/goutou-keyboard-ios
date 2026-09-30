import Foundation

/// 阶段 12E（Final）契约：灵动岛 / 锁屏 Live Activity 的**纯逻辑**——
/// 什么时候创建 / 更新 / 结束、去重与节流，以及「只推状态与计数，绝不推聊天正文」。
///
/// ActivityKit 与真实的灵动岛只能真机验收；这里验的是决策、内容映射与结构保证。
/// 全部虚构文本；不联网、不调 AI、不落盘、不碰输入代理。
var checks = 0
func expect(_ value: Bool, _ description: String) {
    checks += 1
    if !value { fatalError("CaptureActivityCheck: \(description)") }
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)
/// 虚构正文，仅用于证明「没被带出去」
let sensitiveLine = "今晚八点老地方见"

func content(
    capturing: Bool = true,
    gate: ChatSceneVerdict = .activeChat,
    autoSync: LiveChatAutoSyncState = .disabled,
    timeline: Int = 0,
    synced: Int = 0,
    unknown: Int = 0,
    lastSyncAt: Date? = nil,
    error: String? = nil
) -> GoutouCaptureActivityContent {
    GoutouCaptureActivityContent(
        capturing: capturing,
        gateText: gate.shortTitle,
        autoSyncText: autoSync.title,
        timelineCount: timeline,
        syncedCount: synced,
        unknownCount: unknown,
        lastSyncAt: lastSyncAt,
        errorText: error
    )
}

func isUpdate(_ action: GoutouCaptureActivityAction) -> Bool {
    if case .update = action { return true }
    return false
}

// MARK: - 1~3：只有真的开始捕获才建 Activity，而且只建一个

var planner = GoutouCaptureActivityPlanner()
expect(planner.stateChanged(content(timeline: 3), now: t0) == .none,
       "1. 捕获没开始时不创建 Activity（不留假灵动岛）")
expect(!planner.isRunning, "1b. 没开始时规划器也不在跑")
expect(planner.skippedUpdates == 1, "1c. 没开始时的变化被记成「跳过」")

expect(planner.captureStarted(sessionID: "session-1", content: content(timeline: 0), now: t0)
        == .start(content(timeline: 0)),
       "2. 真正开始捕获后请求创建一个 Activity")
expect(planner.isRunning, "2b. 开始后规划器进入运行态")
expect(planner.sessionID == "session-1", "2c. Activity 记住本轮 session")

let secondAction = planner.stateChanged(content(timeline: 1), now: t0.addingTimeInterval(2))
expect(isUpdate(secondAction), "3. 运行期间只可能是 update，绝不重复 start")
expect(secondAction != .start(content(timeline: 1)), "3b. 第二条消息不会又建一个 Activity")

// MARK: - 4~6：状态与计数如实映射

let syncedAt = t0.addingTimeInterval(5)
let mapped = GoutouCaptureActivityContentBuilder.make(
    captureState: .capturing,
    verdict: .activeChat,
    autoSync: .synced(messageCount: 7, at: syncedAt),
    timelineCount: 12,
    unknownCount: 2,
    syncedCount: 7,
    lastSyncAt: syncedAt
)
expect(mapped.capturing, "4. 捕获状态如实映射（在跑）")
expect(mapped.gateText == ChatSceneVerdict.activeChat.shortTitle, "4b. 门控文案只说状态：\(mapped.gateText)")
expect(mapped.timelineCount == 12, "4c. 实时聊天条数如实映射")
expect(mapped.syncedCount == 7, "5. 已同步条数如实映射")
expect(mapped.lastSyncAt == syncedAt, "5b. 最后同步时间如实映射")
expect(mapped.unknownCount == 2, "6. 未确定条数如实映射")
expect(mapped.autoSyncText == LiveChatAutoSyncState.synced(messageCount: 7, at: syncedAt).title,
       "6b. 自动同步文案如实映射")
expect(mapped.autoSyncText.contains("7"), "6c. 自动同步文案带的是条数，不是正文")
expect(!mapped.autoSyncText.contains(sensitiveLine), "6d. 自动同步文案里没有正文")

let notCapturing = GoutouCaptureActivityContentBuilder.make(
    captureState: .stopped,
    verdict: .inactive,
    autoSync: .disabled,
    timelineCount: 4,
    unknownCount: 0,
    syncedCount: 0,
    lastSyncAt: nil
)
expect(!notCapturing.capturing, "6e. 已停止时 capturing=false")
expect(notCapturing.errorText == nil, "6f. 正常停止没有错误文案")

// MARK: - 7：状态里绝不含聊天正文

/// 模拟主 App 的映射：只取条数与未确定数，正文一个字都不带过去。
struct FakeTimeline {
    var texts: [String]
    var unknown: Int
    var count: Int { texts.count }
}

let fake = FakeTimeline(texts: [sensitiveLine, "好"], unknown: 1)
let built = GoutouCaptureActivityContentBuilder.make(
    captureState: .capturing,
    verdict: .activeChat,
    autoSync: .disabled,
    timelineCount: fake.count,
    unknownCount: fake.unknown,
    syncedCount: 0,
    lastSyncAt: nil
)
expect(!built.summary.contains(sensitiveLine), "7. 灵动岛内容里不含聊天正文")
expect(built.summary.contains("timeline=2"), "7b. 只带状态与计数：\(built.summary)")
expect(!built.summary.contains("http"), "7c. 内容里没有 URL / 端点")

// MARK: - 10~11：去重与节流

var deduper = GoutouCaptureActivityPlanner()
_ = deduper.captureStarted(sessionID: "s", content: content(timeline: 2), now: t0)
expect(deduper.stateChanged(content(timeline: 2), now: t0.addingTimeInterval(5)) == .none,
       "10. 相同状态不重复 update（哪怕过了很久）")
expect(deduper.stateChanged(content(timeline: 2), now: t0.addingTimeInterval(9)) == .none,
       "10b. 一直相同就一直不推")

var throttled = GoutouCaptureActivityPlanner()
_ = throttled.captureStarted(sessionID: "s", content: content(timeline: 0), now: t0)
expect(throttled.stateChanged(content(timeline: 1), now: t0.addingTimeInterval(0.2)) == .none,
       "11. 变化太快先被节流挡掉（不按帧推灵动岛）")
expect(throttled.stateChanged(content(timeline: 2), now: t0.addingTimeInterval(0.4)) == .none,
       "11b. 节流窗口内继续只留最后一次")
expect(throttled.stateChanged(content(timeline: 3), now: t0.addingTimeInterval(1.5))
        == .update(content(timeline: 3)),
       "11c. 过了最小间隔才真的推一次（中间的都被合并掉）")
expect(throttled.skippedUpdates == 2, "11d. 被挡掉的次数有统计：\(throttled.skippedUpdates)")
expect(GoutouCaptureActivityPlanner().minimumUpdateInterval >= 1.0,
       "11e. 最小更新间隔不短于 1 秒")

// MARK: - 12：停止 → 结束

var stopper = GoutouCaptureActivityPlanner()
_ = stopper.captureStarted(sessionID: "s", content: content(timeline: 4), now: t0)
let stoppedContent = content(capturing: false, gate: .inactive, timeline: 4)
expect(stopper.captureStopped(stoppedContent, now: t0.addingTimeInterval(3)) == .end(stoppedContent),
       "12. 停止后结束 Activity")
expect(!stopper.isRunning, "12b. 结束后规划器不再运行")
expect(stopper.sessionID == nil, "12c. 结束后不再挂着 session")
expect(stopper.stateChanged(content(timeline: 5), now: t0.addingTimeInterval(6)) == .none,
       "12d. 已经结束的 Activity 不会再被更新（时间线继续涨也不复活）")

// MARK: - 13：失败 → 带错误状态收尾

var failer = GoutouCaptureActivityPlanner()
_ = failer.captureStarted(sessionID: "s", content: content(timeline: 2), now: t0)
let failedContent = GoutouCaptureActivityContentBuilder.make(
    captureState: .failed("启动屏幕捕获失败"),
    verdict: .unknown,
    autoSync: .failed("同步失败：写不进去"),
    timelineCount: 2,
    unknownCount: 0,
    syncedCount: 0,
    lastSyncAt: nil
)
expect(failedContent.errorText == "同步失败：写不进去", "13. 失败时带上错误状态")
expect(!failedContent.capturing, "13b. 失败后不再是「捕获中」")
expect(failer.captureStopped(failedContent, now: t0.addingTimeInterval(2)) == .end(failedContent),
       "13c. 失败后 Activity 正确结束（End 带着错误状态）")

// MARK: - 14：新一轮 capture 建新的 Activity

var restart = GoutouCaptureActivityPlanner()
_ = restart.captureStarted(sessionID: "session-A", content: content(timeline: 1), now: t0)
_ = restart.captureStopped(content(capturing: false, error: "启动屏幕捕获失败"),
                           now: t0.addingTimeInterval(1))
expect(restart.captureStarted(sessionID: "session-B", content: content(timeline: 0),
                              now: t0.addingTimeInterval(30)) == .start(content(timeline: 0)),
       "14. 新 session 请求一个全新的 Activity")
expect(restart.sessionID == "session-B", "14b. 新 session 绝不复用已经结束的那个")

// MARK: - 控制器：ActivityKit 只在内存里做，失败不致命

let controller = GoutouCaptureActivityController()
expect(!controller.isRunning, "15. 控制器初始不在跑（不伪造灵动岛）")
controller.captureStarted(sessionID: "s", content: content(timeline: 0), now: t0)
expect(controller.isRunning, "15b. 开始后控制器进入运行态")
expect(controller.lastError?.contains(sensitiveLine) != true,
       "15c. 就算 ActivityKit 失败，错误文案里也没有正文")
controller.captureStopped(content(capturing: false), now: t0.addingTimeInterval(4))
expect(!controller.isRunning, "15d. 停止后控制器回到不在跑")

// MARK: - 结构保证：新代码不碰 AI / 输入代理 / 聊天存储 / 路径

let scannedFiles = [
    "App/ScreenCapture/GoutouCaptureActivityState.swift",
    "App/ScreenCapture/GoutouCaptureActivityController.swift",
    "Shared/LiveActivity/GoutouCaptureActivityAttributes.swift",
    "Widget/GoutouCaptureActivityWidget.swift",
    "Widget/GoutouCaptureControl.swift",
    "Widget/GoutouCaptureWidgetBundle.swift",
]
var sources: [String: String] = [:]
for path in scannedFiles {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fatalError("CaptureActivityCheck: 读不到 \(path)")
    }
    sources[path] = text
}

let forbidden = [
    "GoutouAIClient", "URLSession", "Authorization", "apiKey", "APIKey",
    "insertText", "textDocumentProxy", "UIPasteboard",
    "SharedChatStore", "containerURL", "applicationGroupIdentifier",
    "latest_chat", "UserDefaults", "fatalError", "try!",
]
for (path, text) in sources.sorted(by: { $0.key < $1.key }) {
    for token in forbidden {
        expect(!text.contains(token), "16. \(path) 不该出现 \(token)")
    }
    // 灵动岛 / 锁屏只画状态：不出现聊天字段名
    for token in ["messageText", "chatText", "messages:", "GoutouChatClipboardMessage"] {
        expect(!text.contains(token), "16b. \(path) 不该出现 \(token)")
    }
}

// 控制中心：只把 App 打开，不绕系统授权、不自己开捕获、不调 AI
guard let controlSource = sources["Widget/GoutouCaptureControl.swift"] else {
    fatalError("CaptureActivityCheck: 缺 Control 源码")
}
expect(controlSource.contains("openAppWhenRun"), "17. Control 用系统允许的「打开 App」语义")
for token in ["SCContentSharingPicker", "SCStream", "startCapture", "SCContentFilter",
              "ControlWidgetToggle"] {
    expect(!controlSource.contains(token), "17b. Control 不该出现 \(token)")
}
expect(controlSource.contains("ControlWidgetButton"), "17c. Control 就是一个按钮")

// 主 App：控制器真的接上了，而且每轮 capture 都是新 session
guard let managerSource = try? String(contentsOfFile: "App/ScreenCapture/LiveScreenCaptureManager.swift",
                                      encoding: .utf8) else {
    fatalError("CaptureActivityCheck: 读不到 LiveScreenCaptureManager.swift")
}
expect(managerSource.contains("captureActivity.captureStarted"), "18. 主 App 接上了灵动岛控制器")
expect(managerSource.contains("captureActivity.stateChanged"), "18b. OCR 回来后推一次状态")
expect(managerSource.contains("noteCaptureActivityStopped()"), "18c. 停止 / 失败会收掉 Activity")
expect(managerSource.contains("captureSessionID = UUID().uuidString"), "18d. 每轮 capture 都是新 session")
expect(managerSource.contains("isSystemSupported"), "18e. 没有为了灵动岛提高系统要求")
expect(managerSource.contains("guard model.state.isCapturing else { return }"),
       "18f. 没真的在捕获就不建 Activity")
// 灵动岛是辅助显示：主链路不依赖 ActivityKit 成功
expect(!managerSource.contains("guard captureActivity"), "18g. 主链路不依赖 ActivityKit 成功")

// App Info.plist 声明支持 Live Activity
guard let appInfo = try? String(contentsOfFile: "App/Info.plist", encoding: .utf8) else {
    fatalError("CaptureActivityCheck: 读不到 App/Info.plist")
}
expect(appInfo.contains("NSSupportsLiveActivities"), "19. 主 App 声明支持 Live Activity")
guard let widgetInfo = try? String(contentsOfFile: "Widget/Info.plist", encoding: .utf8) else {
    fatalError("CaptureActivityCheck: 读不到 Widget/Info.plist")
}
expect(widgetInfo.contains("com.apple.widgetkit-extension"), "19b. Widget 扩展的 point 正确")
expect(!widgetInfo.contains("latest_chat"), "19c. Widget 扩展的 plist 里没有聊天文件")

print("CaptureActivityCheck passed (\(checks) assertions; pure logic + source contract; no network)")
