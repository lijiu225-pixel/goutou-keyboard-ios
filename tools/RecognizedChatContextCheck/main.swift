import Foundation

/// 阶段 8 的契约：识别聊天「预览 → 使用 → 取消使用 → 重新读取 → 读取失败」。
///
/// 只跑临时目录里的真实文件 I/O；全部使用虚构聊天。
/// 这里**不**证明真机 App Group 权限，也**不**发网络请求。
/// 「使用这份聊天不得联网」由结构保证：状态机不持有任何网络客户端，
/// 控制器的 `.useRecognizedChat` 分支只改状态，不碰 GoutouAIClient。
var checks = 0
func expect(_ value: Bool, _ description: String) {
    checks += 1
    if !value { fatalError("RecognizedChatContextCheck: \(description)") }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("RecognizedChatContextCheck-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

let store = SharedChatStore(testContainer: root)
let directory = root.appendingPathComponent(SharedConstants.chatDirectory)
let file = directory.appendingPathComponent(SharedConstants.latestChatFilename)
let t0 = Date(timeIntervalSince1970: 1_700_000_000.125)

func chat(_ count: Int, _ seed: String) -> [GoutouChatClipboardMessage] {
    (0..<count).map { GoutouChatClipboardMessage(role: $0 % 2 == 0 ? .me : .other, text: "\(seed)第\($0)条\n第二行") }
}
let chatA = chat(8, "甲")
let chatB = chat(3, "乙")

func save(_ messages: [GoutouChatClipboardMessage], at date: Date) throws {
    try store.save(GoutouChatClipboardPayload(messages: messages), updatedAt: date)
}
func writeFixture(version: Any = 1, format: String = "goutou-chat",
                  messages: [[String: Any]] = [["role": "me", "text": "测试"]]) throws {
    let object: [String: Any] = ["format": format, "version": version,
                                "updatedAt": "2023-11-14T22:13:20.125Z", "messages": messages]
    try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
}
func overwrite(_ text: String) throws {
    try Data(text.utf8).write(to: file)
}

var session = RecognizedChatSession()

// A：还没读过
expect(session.status == .notLoaded, "fresh session is notLoaded")
expect(session.preview == nil && session.active == nil && session.errorMessage == nil, "fresh session is empty")
expect(!session.canUsePreview, "nothing can be used before reading")
expect(!session.usePreview(), "use before read is refused")
expect(session.status == .notLoaded, "a refused use keeps notLoaded")

// 1. 读取 ≠ 使用
try save(chatA, at: t0)
session.read { try store.read() }
expect(session.preview?.messages == chatA, "preview keeps text, role and order")
expect(abs((session.preview?.updatedAt.timeIntervalSince(t0)) ?? .infinity) < 0.001, "preview keeps the save time")
expect(session.active == nil, "reading alone must not activate a context")
expect(session.status == .previewing(messageCount: 8), "successful read enters previewing")
expect(session.canUsePreview, "a valid preview offers the use action")
expect(session.errorMessage == nil, "successful read clears the error")

// 2~6. 使用后：条数、正文、role、顺序、时间都不变
expect(session.usePreview(), "use succeeds with a valid preview")
guard let active = session.active else { fatalError("RecognizedChatContextCheck: active context missing") }
expect(active.messageCount == 8, "active context message count")
expect(active.messages == chatA, "active messages keep text, role and order")
expect(abs(active.updatedAt.timeIntervalSince(t0)) < 0.001, "active context keeps updatedAt")
expect(session.status == .inUse(messageCount: 8), "use enters inUse")
expect(!session.canUsePreview, "an already active chat is not offered for use again")

// 7~8. 取消使用：只清活动上下文，预览和共享文件都在
session.cancelUse()
expect(session.active == nil, "cancel clears the active context")
expect(session.status == .previewing(messageCount: 8), "cancel falls back to previewing")
expect(session.preview?.messages == chatA, "cancel keeps the preview")
expect(session.canUsePreview, "cancel offers the use action again")
expect(try store.read().messages == chatA, "cancel use must not delete the shared chat file")

// 15~18. 30 分钟边界沿用阶段 7 的判定；旧聊天仍然允许使用
guard let staleCandidate = session.preview else { fatalError("RecognizedChatContextCheck: preview missing") }
expect(!staleCandidate.isOlderThanThirtyMinutes(now: t0.addingTimeInterval(1799.999)), "29:59 is not old")
expect(!staleCandidate.isOlderThanThirtyMinutes(now: t0.addingTimeInterval(1800)), "30:00 is not old")
expect(staleCandidate.isOlderThanThirtyMinutes(now: t0.addingTimeInterval(1800.001)), "30:01 is old")
_ = session.usePreview()
expect(session.status == .inUse(messageCount: 8), "an old chat can still be used")

// 9. 读取聊天 B：旧的活动上下文先失效，B 只是预览
try save(chatB, at: t0.addingTimeInterval(60))
session.read { try store.read() }
expect(session.active == nil, "re-reading invalidates the previous active context")
expect(session.preview?.messages == chatB, "only the newly read chat is previewed")
expect(session.status == .previewing(messageCount: 3), "the new chat waits for an explicit use")
_ = session.usePreview()
expect(session.status == .inUse(messageCount: 3), "chat B becomes active only after use")

// 10. 文件不存在
try store.clear()
session.read { try store.read() }
expect(session.preview == nil, "a missing file clears the preview")
expect(session.active == nil, "a missing file clears the active context")
expect(session.errorMessage == SharedChatStoreError.notSaved.errorDescription, "a missing file reports 尚未保存")
expect(session.status == .notLoaded, "a missing file falls back to notLoaded")

// 11. JSON 损坏
try save(chatA, at: t0)
session.read { try store.read() }
_ = session.usePreview()
expect(session.active != nil, "chat A is active before the damaged read")
try overwrite("{broken")
session.read { try store.read() }
expect(session.preview == nil && session.active == nil, "damaged JSON clears both preview and active context")
expect(session.errorMessage == SharedChatStoreError.damagedJSON.errorDescription, "damaged JSON message")

// 12. version 不支持
try save(chatA, at: t0)
session.read { try store.read() }
_ = session.usePreview()
expect(session.active != nil, "chat A is active before the unsupported-version read")
try writeFixture(version: 2)
session.read { try store.read() }
expect(session.preview == nil && session.active == nil, "an unsupported version clears both states")
expect(session.errorMessage == SharedChatStoreError.invalidChat(.unsupportedVersion(2)).errorDescription,
       "unsupported version message")

// 没开完全访问：连读取都发起不了，同样先作废旧状态
try save(chatA, at: t0)
session.read { try store.read() }
_ = session.usePreview()
session.invalidate(withError: "没有开启键盘完全访问。")
expect(session.preview == nil && session.active == nil, "no full access clears both states")
expect(session.errorMessage == "没有开启键盘完全访问。", "no full access message")

// 13~14. 空聊天 / 非法聊天都进不了活动上下文
var emptyPreview = RecognizedChatSession(preview: SharedChatSnapshot(messages: [], updatedAt: t0))
expect(!emptyPreview.canUsePreview, "an empty preview is not usable")
expect(!emptyPreview.usePreview(), "an empty preview cannot activate")
expect(emptyPreview.active == nil, "an empty chat never becomes the active context")
try writeFixture(messages: [["role": "unknown", "text": "测试"]])
session.read { try store.read() }
expect(session.preview == nil, "an invalid role is never previewed")
expect(!session.usePreview(), "an invalid chat cannot be used")
expect(session.active == nil, "an invalid chat never becomes the active context")

// 19~20. 不联网、不持久化：使用/取消都不会往容器里多写一个文件
try save(chatA, at: t0)
session.read { try store.read() }
let beforeUse = try fm.contentsOfDirectory(atPath: directory.path).sorted()
_ = session.usePreview()
session.cancelUse()
let afterUse = try fm.contentsOfDirectory(atPath: directory.path).sorted()
expect(beforeUse == afterUse, "use and cancel write nothing into the container")
expect(Mirror(reflecting: session).displayStyle == .struct, "the state machine is a value type with no shared client")
expect(UserDefaults.standard.object(forKey: "goutou.recognizedChat.context") == nil,
       "the active context is not persisted in UserDefaults")

print("RecognizedChatContextCheck passed (\(checks) assertions; temporary filesystem only; no network)")
