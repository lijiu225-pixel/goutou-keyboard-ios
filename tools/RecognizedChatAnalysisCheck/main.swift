import Foundation

/// 阶段 9 的契约：Active Context →「分析这段聊天」→ 现有 AI 网络层 → 一份聊天分析。
///
/// 纯 Foundation，**不联网**：请求只用 `buildURLRequest` 组装出来检查内容，不真的发出去；
/// 测试里的聊天全是虚构的（今晚吃什么这类），不涉及任何真实对话。
/// 这里也**不**证明真机签名权限。
var checks = 0
func expect(_ value: Bool, _ description: String) {
    checks += 1
    if !value { fatalError("RecognizedChatAnalysisCheck: \(description)") }
}
func expectThrows(_ expected: GoutouAIError, _ description: String, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        fatalError("RecognizedChatAnalysisCheck: \(description)（没有报错）")
    } catch let error as GoutouAIError {
        if error != expected { fatalError("RecognizedChatAnalysisCheck: \(description)（得到 \(error)）") }
    } catch {
        fatalError("RecognizedChatAnalysisCheck: \(description)（非预期错误）")
    }
}

// MARK: - 虚构数据

let messages = [
    GoutouChatClipboardMessage(role: .other, text: "今晚吃什么"),
    GoutouChatClipboardMessage(role: .me, text: "都可以"),
    GoutouChatClipboardMessage(role: .other, text: "那吃火锅吧"),
    GoutouChatClipboardMessage(role: .me, text: "好，七点老地方"),
]
let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
let context = RecognizedChatContext(messages: messages, updatedAt: savedAt)
let config = GoutouConfig(baseURL: "https://example.invalid/v1", model: "test-model", apiKey: "test-key")
let skillFixture = "SKILL-BODY-不动的军师人格"

var session = RecognizedChatAnalysisSession()
/// 记录「真的发起了几次请求」：只有 `.started` 才算一次。
var starts = 0
func note(_ outcome: RecognizedChatAnalysisStart) -> RecognizedChatAnalysisStart {
    if case .started = outcome { starts += 1 }
    return outcome
}

// MARK: - 准入：只有用户点分析、且有 Active Context 才发请求

// 1. 只有预览、没有 Active Context
expect(note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: nil)) == .blocked(.noActiveContext),
       "预览不能直接分析")
expect(session.state == .failure(.noActiveContext), "被挡下时要说明原因")
expect(starts == 0, "没有 Active Context 时不得发请求")

// 3 / 4 / 5 / 21：读取、使用、重新显示预览都不发请求
session.invalidate()
expect(session.state == .idle, "读取识别聊天只清分析状态")
expect(starts == 0, "读取识别聊天不得发请求（使用这份聊天同理：它不碰分析状态机）")

// 18. 没有完全访问
session.invalidate()
expect(note(session.begin(hasFullAccess: false, config: config, skillAvailable: true, context: context)) == .blocked(.noFullAccess),
       "没有完全访问不发请求")
expect(starts == 0, "没有完全访问时请求数不变")

// 19. 配置缺失（baseURL / model 任一为空）
session.invalidate()
expect(note(session.begin(hasFullAccess: true, config: nil, skillAvailable: true, context: context)) == .blocked(.notConfigured),
       "没有配置不发请求")
expect(note(session.begin(hasFullAccess: true, config: GoutouConfig.empty, skillAvailable: true, context: context)) == .blocked(.notConfigured),
       "配置不完整不发请求")
expect(starts == 0, "配置缺失时请求数不变")

// 人格没打进包
session.invalidate()
expect(note(session.begin(hasFullAccess: true, config: config, skillAvailable: false, context: context)) == .blocked(.missingSkill),
       "军师人格缺失时不发请求")

// 2 / 5 / 6：有 Active Context，用户点分析才刚好开始一次
session.invalidate()
guard case .started(let generationA) = note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) else {
    fatalError("RecognizedChatAnalysisCheck: 有效上下文应当能发起分析")
}
expect(starts == 1, "一次点击只发一次请求")
expect(session.isAnalyzing, "请求期间是 loading")

// 13. 请求期间重复点击不并发
expect(note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) == .blocked(.alreadyRunning),
       "分析中重复点击被挡下")
expect(starts == 1, "重复点击不得发出第二次请求")
expect(session.isAnalyzing, "被挡下不能把 loading 冲掉")

// MARK: - 成功 / 失败 / 空响应

// 10. 成功
session.complete(generation: generationA, result: .success("对方在确认今晚的安排。"))
expect(session.state == .success("对方在确认今晚的安排。"), "成功进入 success")

// 12. 空响应不能算成功
session.invalidate()
guard case .started(let generationEmpty) = note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) else {
    fatalError("RecognizedChatAnalysisCheck: 空响应用例没能发起")
}
session.complete(generation: generationEmpty, result: .success("  \n "))
expect(session.state == .failure(.ai(.empty)), "空响应不得显示成功")

// 11. 失败
session.invalidate()
guard case .started(let generationFail) = note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) else {
    fatalError("RecognizedChatAnalysisCheck: 失败用例没能发起")
}
session.complete(generation: generationFail, result: .failure(.ai(.timeout)))
expect(session.state == .failure(.ai(.timeout)), "失败进入 failure")

// 错误文案：区分得开，又不回显服务器原文 / Key
expect(RecognizedChatAnalysisError.noFullAccess.message.contains("完全访问"), "完全访问错误能认出来")
expect(RecognizedChatAnalysisError.notConfigured.message.contains("还没配置"), "配置错误能认出来")
expect(RecognizedChatAnalysisError.ai(.timeout).message.contains("超时"), "超时能认出来")
expect(RecognizedChatAnalysisError.ai(.http(401, "服务器原文")).message.contains("401"), "HTTP 错误带状态码")
expect(!RecognizedChatAnalysisError.ai(.http(401, "服务器原文")).message.contains("服务器原文"), "不把服务器原文给用户")
expect(!RecognizedChatAnalysisError.ai(.network("https://internal.example.invalid/x")).message.contains("internal.example.invalid"),
       "网络错误不回显内部地址")

// MARK: - 上下文变化 / 异步竞态

// 14. 读取聊天 B：结果 A 立即消失
session.invalidate()
guard case .started(let generationOld) = note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) else {
    fatalError("RecognizedChatAnalysisCheck: 清除旧结果用例没能发起")
}
session.complete(generation: generationOld, result: .success("A 的分析"))
expect(session.state == .success("A 的分析"), "先有一份 A 的分析")
session.invalidate()
expect(session.state == .idle, "读取聊天 B 时结果 A 被清除")

// 15. 取消使用：结果 A 也被清除
session.invalidate()
guard case .started(let generationCancelUse) = note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) else {
    fatalError("RecognizedChatAnalysisCheck: 取消使用用例没能发起")
}
session.complete(generation: generationCancelUse, result: .success("A 的分析"))
expect(session.state == .success("A 的分析"), "再有一份 A 的分析")
session.invalidate()
expect(session.state == .idle, "取消使用识别聊天会清掉分析结果")

// 16. A 还在路上，用户读了 B：A 返回后不得写回
session.invalidate()
guard case .started(let staleA) = note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) else {
    fatalError("RecognizedChatAnalysisCheck: 竞态（读取 B）用例没能发起")
}
session.invalidate()
session.complete(generation: staleA, result: .success("A 的分析"))
expect(session.state == .idle, "A 的迟到响应不能写进新上下文")

// 17. A 还在路上，用户取消使用（或收起面板）：返回后同样不得写回
session.invalidate()
guard case .started(let staleB) = note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) else {
    fatalError("RecognizedChatAnalysisCheck: 竞态（取消）用例没能发起")
}
session.cancelInFlight()
expect(session.state == .idle, "收起面板时在途分析作废")
session.complete(generation: staleB, result: .success("A 的分析"))
expect(session.state == .idle, "迟到响应在作废之后一个字都不写")

// 代际号确实随时在涨
expect(session.generation > 0, "状态机持有一个代际号")

// MARK: - Prompt：阶段 9 只要求一份 analysis

guard let userMessage = RecognizedChatPrompt.userMessage(messages: messages) else {
    fatalError("RecognizedChatAnalysisCheck: 正常聊天应当能拼出 user message")
}
let phase9System = RecognizedChatPrompt.systemPrompt(skill: skillFixture)

expect(phase9System.hasPrefix(skillFixture), "阶段 9 仍然加载原来的 skill 原文")
expect(phase9System.contains("{\"analysis\""), "阶段 9 只要求 analysis 一个字段")

// 6~9. 条数 / 正文 / role / 顺序
let renderedLines = userMessage.components(separatedBy: "\n")
let chatLines = renderedLines.filter { $0.hasPrefix("我：") || $0.hasPrefix("对方：") }
expect(chatLines.count == messages.count, "请求里的消息条数与上下文一致")
var orderKept = true
var cursor = userMessage.startIndex
for message in messages {
    let line = "\(message.role.displayName)：\(message.text)"
    guard let range = userMessage.range(of: line, range: cursor..<userMessage.endIndex) else {
        orderKept = false
        break
    }
    cursor = range.upperBound
}
expect(orderKept, "请求保持原顺序、原正文、原归属")
expect(userMessage.contains("我：都可以"), "「我」保持是 me")
expect(userMessage.contains("对方：今晚吃什么"), "「对方」保持是 other")

// 10. 阶段 9 的 Prompt 不得再要求推荐回复
for forbidden in ["replies", "6～8", "6~8", "推荐回复", "回复话术"] {
    expect(!phase9System.contains(forbidden), "阶段 9 system prompt 不得要求 \(forbidden)")
    expect(!userMessage.contains(forbidden), "阶段 9 user message 不得要求 \(forbidden)")
}

// 原来的狗头军师 Prompt（手动上下文 / 推荐回复 / 记忆链路）没被动过
let legacySystem = GoutouPrompt.systemPrompt(skill: skillFixture)
expect(legacySystem.hasPrefix(skillFixture), "旧 prompt 仍然以 skill 原文开头")
expect(legacySystem.contains("replies"), "旧 prompt 仍然要求 replies")
expect(legacySystem.contains("6～8"), "旧 prompt 仍然保留 6～8 条的契约")

// 10 / 11. 不该出现在请求里的东西
for leaked in [SharedConstants.appGroupID, SharedConstants.chatDirectory, SharedConstants.latestChatFilename,
               "com.example.goutouinput", "updatedAt", "已使用识别聊天", "聊天内容可能较旧",
               "读取识别聊天", "使用这份聊天", "1700000000"] {
    expect(!userMessage.contains(leaked), "请求里不得出现 \(leaked)")
}

// 边界：空聊天 / 超条数 / 空白正文 / 超长正文都不拼 Prompt
expect(RecognizedChatPrompt.userMessage(messages: []) == nil, "空聊天不拼 Prompt")
expect(RecognizedChatPrompt.userMessage(messages: Array(repeating: GoutouChatClipboardMessage(role: .me, text: "占位"),
                                                        count: GoutouChatClipboardCodec.maxMessages + 1)) == nil,
       "超过条数上限不拼 Prompt")
expect(RecognizedChatPrompt.userMessage(messages: [GoutouChatClipboardMessage(role: .me, text: "   ")]) == nil,
       "空白正文不拼 Prompt")
expect(RecognizedChatPrompt.userMessage(messages: [GoutouChatClipboardMessage(
    role: .other, text: String(repeating: "长", count: GoutouChatClipboardCodec.maxMessageLength + 1))]) == nil,
       "超过单条长度上限不拼 Prompt")

// MARK: - 真正会发出去的那个请求（只组装，不发送）

let request = try GoutouAIClient.buildURLRequest(config: config, systemPrompt: phase9System, userMessage: userMessage)
expect(request.httpMethod == "POST", "请求是 POST")
expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "Key 只在请求头里")
expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "Content-Type 照旧")
let body = request.httpBody ?? Data()
let bodyText = String(data: body, encoding: .utf8) ?? ""
guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
      let sent = root["messages"] as? [[String: Any]] else {
    fatalError("RecognizedChatAnalysisCheck: 请求体不是预期结构")
}
expect(sent.count == 2, "system + user 两条消息")
expect(sent[0]["role"] as? String == "system", "第一条是 system")
expect(sent[0]["content"] as? String == phase9System, "system 就是阶段 9 的 Prompt")
expect(sent[1]["role"] as? String == "user", "第二条是 user")
expect(sent[1]["content"] as? String == userMessage, "user 就是 Builder 的输出")
expect(root["model"] as? String == "test-model", "模型沿用配置")
expect(root["stream"] as? Bool == false, "非流式请求照旧")
expect(!bodyText.contains("test-key"), "Key 不得进请求体")
expect(!bodyText.contains("replies"), "请求体里不得要求 replies")

func response(_ content: String, finish: String = "stop", reasoning: String? = nil) -> Data {
    var message: [String: Any] = ["role": "assistant", "content": content]
    if let reasoning = reasoning { message["reasoning_content"] = reasoning }
    let payload: [String: Any] = ["choices": [["message": message, "finish_reason": finish]]]
    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
}

// MARK: - 返回解析：只要一份分析

let analysisField = try GoutouAIClient.parseAnalysisResponse(data: response("{\"analysis\":\"对方在确认今晚的安排。\"}"))
expect(analysisField == "对方在确认今晚的安排。", "analysis 字段")
let fenced = try GoutouAIClient.parseAnalysisResponse(data: response("```json\n{\"analysis\":\"带围栏的分析\"}\n```"))
expect(fenced == "带围栏的分析", "代码围栏容错")
let legacyBody = "{\"relationship\":\"关系分析正文。\",\"replies\":[\"话术一\",\"话术二\"]}"
let legacyAnalysis = try GoutouAIClient.parseAnalysisResponse(data: response(legacyBody))
expect(legacyAnalysis == "关系分析正文。", "兼容旧返回格式时只取分析")
expect(!legacyAnalysis.contains("话术"), "旧格式里的 replies 一律不展示")
let prose = try GoutouAIClient.parseAnalysisResponse(data: response("对方像是在确认时间。"))
expect(prose == "对方像是在确认时间。", "模型直接给一段文字也认")
let fromReasoning = try GoutouAIClient.parseAnalysisResponse(data: response("", reasoning: "推理里写的结论"))
expect(fromReasoning == "推理里写的结论", "只回思考时退一步用思考里的结论")
let longAnalysis = String(repeating: "长", count: GoutouAIClient.maxAnalysisLength + 500)
let capped = try GoutouAIClient.parseAnalysisResponse(data: response("{\"analysis\":\"\(longAnalysis)\"}"))
expect(capped.count == GoutouAIClient.maxAnalysisLength + 1 && capped.hasSuffix("…"), "过长的分析截断加省略号")
expectThrows(.empty, "空内容") { _ = try GoutouAIClient.parseAnalysisResponse(data: response("")) }
expectThrows(.truncated, "只被截断、没有任何正文") {
    _ = try GoutouAIClient.parseAnalysisResponse(data: response("", finish: "length"))
}
expectThrows(.badJSON("不是 JSON"), "响应体不是 JSON") { _ = try GoutouAIClient.parseAnalysisResponse(data: Data("不是 JSON".utf8)) }

// MARK: - 20. 不落盘、不写记忆

// 走完一整轮「开始 → 成功 → 读取新聊天作废」，容器里不该多出任何文件。
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("RecognizedChatAnalysisCheck-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let beforeRun = try fm.contentsOfDirectory(atPath: root.path)
var cycle = RecognizedChatAnalysisSession()
if case .started(let cycleGeneration) = cycle.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context) {
    cycle.complete(generation: cycleGeneration, result: .success("一轮分析"))
}
cycle.invalidate()
let afterRun = try fm.contentsOfDirectory(atPath: root.path)
expect(beforeRun == afterRun, "分析不往磁盘多写任何文件")
expect(cycle.state == .idle, "一轮走完回到 idle")
expect(UserDefaults.standard.object(forKey: "goutou.recognizedChat.analysis") == nil, "分析结果不写 UserDefaults")
expect(Mirror(reflecting: session).displayStyle == .struct, "分析状态机是值类型，不持有网络客户端")

print("RecognizedChatAnalysisCheck passed (\(checks) assertions; prompts and state only; no network)")
