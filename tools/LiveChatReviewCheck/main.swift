import CoreGraphics
import Foundation

/// 阶段 12C 的纯逻辑契约：Live Timeline → 冻结草稿 → 用户确认 / 修正 → 复用 SharedChatStore 正式保存。
///
/// 全部虚构文本；用临时目录当共享容器。不碰屏幕捕获、不联网、不调 AI、不碰键盘。
var checks = 0
func expect(_ value: Bool, _ description: String) {
    checks += 1
    if !value { fatalError("LiveChatReviewCheck: \(description)") }
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

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

func observation(_ text: String, y: CGFloat) -> LiveOCRObservation {
    LiveOCRObservation(text: text, confidence: 0.9, box: CGRect(x: 0.05, y: y, width: 0.3, height: 0.03))
}

let fm = FileManager.default
func makeRoot(_ tag: String) throws -> URL {
    let url = fm.temporaryDirectory.appendingPathComponent("LiveChatReviewCheck-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let root = try makeRoot("main")
defer { try? fm.removeItem(at: root) }
let store = SharedChatStore(testContainer: root)
let saver = LiveChatReviewSaver(store: store)
let chatFile = root
    .appendingPathComponent(SharedConstants.chatDirectory)
    .appendingPathComponent(SharedConstants.latestChatFilename)

// MARK: - 1~6：从 timeline 生成草稿、顺序、角色映射、system 默认排除

let timeline = [
    candidate("今晚有空吗", role: .other),
    candidate("有啊", role: .me),
    candidate("说不清是谁说的", role: .unknown),
    candidate("21:30", role: .system),
]
var draft = LiveChatReviewDraft(timeline: timeline)
expect(draft.messages.count == 4, "1. Live Timeline 能生成 Review Snapshot")
expect(draft.messages.map(\.text) == ["今晚有空吗", "有啊", "说不清是谁说的", "21:30"], "2. 保持原始消息顺序")
expect(draft.messages[0].originalRole == .other && draft.messages[0].role == .other, "3. other → other")
expect(draft.messages[1].role == .me, "4. me → me")
expect(draft.messages[2].role == .unknown, "5. unknown → unknown（不替用户猜）")
expect(draft.messages[3].isSystem && !draft.messages[3].isIncluded, "6. system 默认排除")
expect(draft.includedCount == 3, "6b. 保留计数不含 system")

// MARK: - 7：草稿冻结，时间线继续涨也不影响

var liveTimeline = LiveChatTimeline()
liveTimeline.merge(timeline, config: .default)
let frozen = LiveChatReviewDraft(timeline: liveTimeline.messages)
liveTimeline.merge([candidate("后来才出现的消息", role: .other)], config: .default)
expect(frozen.messages.count == 4, "7. 时间线新增消息不改变已冻结的草稿")
expect(!frozen.messages.contains { $0.text == "后来才出现的消息" }, "7b. 新消息不会插进旧草稿")

// MARK: - 9~11：unknown 必须由用户处理

let unknownID = draft.messages[2].id
var blocked = false
do {
    _ = try saver.save(draft)
} catch let error as LiveChatReviewError {
    blocked = true
    expect(error == .unresolvedUnknown(1), "11. 未处理的 unknown 阻止保存")
    expect(error.errorDescription?.contains("未确定") == true, "11b. 文案点名未确定归属")
}
expect(blocked, "11c. 未处理 unknown 时保存必须抛错")

var draftToMe = draft
draftToMe.update(id: unknownID, role: .me)
expect(draftToMe.validate() == nil, "9. unknown 改成 me 后可以保存")

var draftToOther = draft
draftToOther.update(id: unknownID, role: .other)
expect(draftToOther.validate() == nil, "10. unknown 改成 other 后可以保存")

var draftExcludedUnknown = draft
draftExcludedUnknown.update(id: unknownID, isIncluded: false)
expect(draftExcludedUnknown.validate() == nil, "12. unknown 被排除后可以保存其它有效消息")

// MARK: - 8 / 14 / 18 / 19 / 20 / 21 / 22：编辑正文、排除、顺序、保存时刻、复用 SharedChatStore

var finalDraft = draft
finalDraft.update(id: unknownID, role: .other)
finalDraft.update(id: finalDraft.messages[1].id, text: "有啊，我七点有空")
finalDraft.update(id: finalDraft.messages[0].id, isIncluded: false)
finalDraft.update(id: finalDraft.messages[3].id, isIncluded: true)   // system 想包含？不许
expect(finalDraft.messages[3].isIncluded == false, "13b. system 永远排除，即使用户点了保留")

let saveTime = Date(timeIntervalSince1970: 1_800_000_000)
let saved = try saver.save(finalDraft, updatedAt: saveTime)
expect(saved.messages.count == 2, "21. 保存的是实际写入的条数")
expect(saved.messages.map(\.text) == ["有啊，我七点有空", "说不清是谁说的"], "8/14/19. 用改后的正文、排除的不写入、顺序不变")
expect(saved.messages.map(\.role) == [.me, .other], "18. 最终 role 只有 me / other")
expect(abs(saved.updatedAt.timeIntervalSince(saveTime)) < 0.001, "20. updatedAt 用保存时刻")

let reader = SharedChatStore(testContainer: root)
let loaded = try reader.read()
expect(loaded.messages.map(\.text) == ["有啊，我七点有空", "说不清是谁说的"], "22. 另一个实例读到相同正文")
expect(loaded.messages.map(\.role) == [.me, .other], "22b. 另一个实例读到相同 role")

var secondDraft = LiveChatReviewDraft(timeline: [candidate("第二次保存", role: .me)])
_ = try saver.save(secondDraft, updatedAt: saveTime.addingTimeInterval(10))
expect(try reader.read().messages.map(\.text) == ["第二次保存"], "23. 第二次保存替换第一份")

// MARK: - 15~17：空正文、全部排除、没有有效消息

let emptyTextDraft = LiveChatReviewDraft(timeline: [candidate("   ", role: .me)])
expect(emptyTextDraft.validate() == .noMessages, "15. 空正文不算有效消息")
expect(emptyTextDraft.savableMessages().isEmpty, "15b. 空正文不会进入正式 messages")

var allExcluded = LiveChatReviewDraft(timeline: [candidate("甲", role: .me), candidate("乙", role: .other)])
for message in allExcluded.messages { allExcluded.update(id: message.id, isIncluded: false) }
expect(allExcluded.validate() == .noMessages, "16. 全部排除后禁止保存")

let emptyTimelineDraft = LiveChatReviewDraft(timeline: [])
expect(emptyTimelineDraft.validate() == .noMessages, "17. 没有有效消息禁止保存")

var systemOnlyDraft = LiveChatReviewDraft(timeline: [candidate("21:30", role: .system), candidate("在的", role: .me)])
expect(systemOnlyDraft.savableMessages().map(\.text) == ["在的"], "13. system 不进入正式 messages")

// MARK: - 24 / 25：保存失败不假装成功，旧共享聊天要留住

try store.save(
    GoutouChatClipboardPayload(messages: [GoutouChatClipboardMessage(role: .me, text: "旧的一份")]),
    updatedAt: saveTime
)
let chatDirectory = root.appendingPathComponent(SharedConstants.chatDirectory)
try fm.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: chatDirectory.path)
var failure: LiveChatReviewError?
do {
    _ = try saver.save(LiveChatReviewDraft(timeline: [candidate("保存不进去", role: .me)]))
} catch let error as LiveChatReviewError {
    failure = error
}
expect(failure != nil, "24. 保存失败必须抛错（不能显示成功）")
if case .saveFailed? = failure { expect(true, "24b. 失败原因沿用 SharedChatStore 的文案") } else { expect(false, "24b. 失败原因沿用 SharedChatStore 的文案") }
try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: chatDirectory.path)
expect(try reader.read().messages.map(\.text) == ["旧的一份"], "25. 保存失败后旧的有效共享聊天仍在")

// MARK: - 26 / 27 / 28：超限继续由现有校验把关

func expectSaveRejected(_ draft: LiveChatReviewDraft, _ description: String) {
    checks += 1
    do {
        _ = try saver.save(draft)
        fatalError("LiveChatReviewCheck: \(description)（竟然保存成功了）")
    } catch let error as LiveChatReviewError {
        if case .saveFailed = error { return }
        fatalError("LiveChatReviewCheck: \(description)（错误类型不对：\(error)）")
    } catch {
        fatalError("LiveChatReviewCheck: \(description)（非预期错误）")
    }
}

let longText = String(repeating: "长", count: GoutouChatClipboardCodec.maxMessageLength + 1)
expectSaveRejected(LiveChatReviewDraft(timeline: [candidate(longText, role: .me)]), "26. 单条超长由现有校验拒绝")

let manyMessages = (0..<(GoutouChatClipboardCodec.maxMessages + 1)).map { candidate("消息\($0)", role: .other) }
expectSaveRejected(LiveChatReviewDraft(timeline: manyMessages), "27. 消息数量超限由现有校验拒绝")

// 28：总长度上限仍由 codec 把关（review 这条链路不绕过它，也不会改小这个常量）
expect(GoutouChatClipboardCodec.maxEncodedLength == 3_500_000, "28. 总长度上限常量没被动过")

// MARK: - 29 / 30：草稿只放内存

let before = try fm.contentsOfDirectory(atPath: root.path)
var memoryOnlyDraft = LiveChatReviewDraft(timeline: timeline)
memoryOnlyDraft.update(id: memoryOnlyDraft.messages[0].id, text: "只改不改存")
memoryOnlyDraft.update(id: memoryOnlyDraft.messages[1].id, role: .other)
_ = memoryOnlyDraft.validate()
_ = memoryOnlyDraft.savableMessages()
let after = try fm.contentsOfDirectory(atPath: root.path)
expect(before == after, "30. 只编草稿不写任何文件")
expect(UserDefaults.standard.object(forKey: "goutou.live.chat.review") == nil, "29. Review Draft 不写 UserDefaults")

// MARK: - 31：实时识别不会自动写共享聊天

let quietRoot = try makeRoot("quiet")
defer { try? fm.removeItem(at: quietRoot) }
let quietFile = quietRoot
    .appendingPathComponent(SharedConstants.chatDirectory)
    .appendingPathComponent(SharedConstants.latestChatFilename)
var liveSystem = LiveChatSystem()
liveSystem.reset(generation: 1)
let frame = [observation("自动识别不该落盘", y: 0.30), observation("也不该自动保存", y: 0.35)]
_ = liveSystem.ingest(observations: frame, timestamp: t0, generation: 1)
_ = liveSystem.ingest(observations: frame, timestamp: t0.addingTimeInterval(0.9), generation: 1)
expect(liveSystem.snapshot().messages.count == 2, "31b. 实时聊天照常积累")
expect(!fm.fileExists(atPath: quietFile.path), "31. 实时识别绝不会自动 SharedChatStore.save")

// MARK: - 34~36：取消 / 清空 / 清除共享聊天各管各的

let sharedBeforeCancel = try reader.read().messages.map(\.text)
_ = LiveChatReviewDraft(timeline: liveSystem.snapshot().messages)   // 打开确认页
// 用户直接返回（取消）：草稿丢掉，不写共享聊天
expect(try reader.read().messages.map(\.text) == sharedBeforeCancel, "34. 取消 Review 不修改共享聊天")

liveSystem.reset(generation: 1)                                     // 「清空实时聊天」
expect(liveSystem.snapshot().messages.isEmpty, "35b. 清空实时聊天后时间线归零")
expect(try reader.read().messages.map(\.text) == sharedBeforeCancel, "35. 清空实时聊天不删除已共享聊天")

_ = try reader.read()
try reader.clear()                                                   // 「清除已共享聊天」
expect(try liveSystem.snapshot().messages.isEmpty, "36. 清除共享聊天不清实时聊天状态")

// MARK: - 32 / 33 / 37~40：源码层保证

let reviewFiles = [
    "App/ScreenCapture/LiveChatReviewDraft.swift",
    "App/LiveChatReviewView.swift",
]
let forbiddenTokens = [
    "GoutouAIClient", "URLSession", "analyzeChat",
    "textDocumentProxy", "insertText", "deleteBackward",
    "GoutouMemory", "runMemoryExtraction", "saveSummary",
    "stopCapture", "clearLiveChat(", "AVCaptureDevice", "PHPhotoLibrary", "Keychain",
]
for file in reviewFiles {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
        expect(false, "读不到源码文件 \(file)")
        continue
    }
    for token in forbiddenTokens {
        expect(!text.contains(token), "\(file) 不该出现 \(token)")
    }
}
// 40：阶段 12C 不碰 Keyboard 目录
expect(reviewFiles.allSatisfy { !$0.hasPrefix("Keyboard/") }, "40. 阶段 12C 的文件都不在 Keyboard 目录")

// The island resumes the same frozen, edited value; new live messages cannot overwrite it.
var editedReview = LiveChatReviewDraft(timeline: Array(timeline.prefix(2)))
let editedID = editedReview.messages[0].id
editedReview.update(id: editedID, role: .me, text: "手动修正的匿名正文", isIncluded: false)
let resumedReview = LiveChatReviewDraft.opening(existing: editedReview, lastSaved: nil,
                                              timeline: timeline + [candidate("后来识别的消息", role: .other)])
expect(resumedReview == editedReview, "island entry preserves edits, roles, selections, order and IDs")
expect(LiveChatReviewDraft.opening(existing: editedReview, lastSaved: nil, timeline: []) == editedReview,
       "an existing unsaved draft is available even when the current timeline is empty")
let nextReview = LiveChatReviewDraft.opening(existing: editedReview, lastSaved: editedReview, timeline: timeline)
expect(nextReview?.messages.count == timeline.count, "an unchanged saved snapshot can advance to the current timeline")
expect(LiveChatReviewDraft.opening(existing: nil, lastSaved: nil, timeline: []) == nil,
       "a cold empty entry cannot fabricate a conversation")
let freshReview = LiveChatReviewDraft.opening(existing: nil, lastSaved: nil, timeline: timeline)
expect(freshReview?.messages.map(\.text) == timeline.map(\.text), "first entry freezes the current messages")
expect(GoutouCaptureLink.opensReview(GoutouCaptureLink.reviewURL), "the widget URL routes to review")
for value in ["goutouinput://chat/save", "goutouinput://chat/review?analyze=1", "goutouinput://chat/review#text",
              "https://chat/review", "goutouinput://other/review", "goutouinput://user:pass@chat/review"] {
    expect(!GoutouCaptureLink.opensReview(URL(string: value)!), "unrecognized URL is ignored: \(value)")
}
let plistData = try Data(contentsOf: URL(fileURLWithPath: "App/Info.plist"))
let appPlist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
let registered = (appPlist["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
expect(registered.contains(GoutouCaptureLink.reviewURL.scheme!), "installed app registers the widget's URL scheme")
let widgetSource = try String(contentsOfFile: "Widget/GoutouCaptureActivityWidget.swift", encoding: .utf8)
expect(widgetSource.components(separatedBy: ".widgetURL(GoutouCaptureLink.reviewURL)").count == 3,
       "both island and lock-screen entry use the same reviewed URL")

print("LiveChatReviewCheck passed (\(checks) assertions; temporary container only; no network)")
