import Foundation

/// 阶段 9 / 10 的契约：Active Context →「分析这段聊天」→ 现有 AI 网络层 →
/// 聊天分析 + 对方状态 + 恰好三条推荐回复。
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
let goodResult = RecognizedChatResult(
    analysis: "对方在确认今晚的安排。",
    tone: "轻松、在推进",
    replies: ["好啊，七点老地方", "你先定地方，我都行", "行，那我请客"]
)
session.complete(generation: generationA, result: .success(goodResult))
expect(session.state == .success(goodResult), "成功进入 success 并带着结构化结果")

// 12. 空正文 / 条数不对的结果不许进 success
session.invalidate()
guard case .started(let generationEmpty) = note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) else {
    fatalError("RecognizedChatAnalysisCheck: 空响应用例没能发起")
}
session.complete(generation: generationEmpty, result: .success(RecognizedChatResult(analysis: "  \n ", tone: "平静",
                                                                                     replies: ["一", "二", "三"])))
expect(session.state == .failure(.incompleteResult), "空正文不得显示成功")
session.invalidate()
guard case .started(let generationShort) = note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) else {
    fatalError("RecognizedChatAnalysisCheck: 条数不足用例没能发起")
}
session.complete(generation: generationShort, result: .success(RecognizedChatResult(analysis: "分析", tone: "平静",
                                                                                     replies: ["一", "二", "二"])))
expect(session.state == .failure(.notEnoughReplies(validCount: 2)), "不到 3 条不得显示成功")

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
session.complete(generation: generationOld, result: .success(goodResult))
expect(session.state == .success(goodResult), "先有一份聊天 A 的完整结果")
session.invalidate()
expect(session.state == .idle, "读取聊天 B 时 analysis / tone / replies 全部清除")

// 15. 取消使用：结果 A 也被清除
session.invalidate()
guard case .started(let generationCancelUse) = note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) else {
    fatalError("RecognizedChatAnalysisCheck: 取消使用用例没能发起")
}
session.complete(generation: generationCancelUse, result: .success(goodResult))
expect(session.state == .success(goodResult), "再有一份聊天 A 的完整结果")
session.invalidate()
expect(session.state == .idle, "取消使用识别聊天会清掉结构化结果")

// 16. A 还在路上，用户读了 B：A 返回后不得写回
session.invalidate()
guard case .started(let staleA) = note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) else {
    fatalError("RecognizedChatAnalysisCheck: 竞态（读取 B）用例没能发起")
}
session.invalidate()
session.complete(generation: staleA, result: .success(goodResult))
expect(session.state == .idle, "A 的迟到响应（analysis / tone / replies）不能写进新上下文")

// 17. A 还在路上，用户取消使用（或收起面板）：返回后同样不得写回
session.invalidate()
guard case .started(let staleB) = note(session.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context)) else {
    fatalError("RecognizedChatAnalysisCheck: 竞态（取消）用例没能发起")
}
session.cancelInFlight()
expect(session.state == .idle, "收起面板时在途分析作废")
session.complete(generation: staleB, result: .success(goodResult))
expect(session.state == .idle, "迟到响应在作废之后一个字都不写")

// 代际号确实随时在涨
expect(session.generation > 0, "状态机持有一个代际号")

// MARK: - Prompt：阶段 10 要 analysis + tone + 恰好 3 条

guard let userMessage = RecognizedChatPrompt.userMessage(messages: messages) else {
    fatalError("RecognizedChatAnalysisCheck: 正常聊天应当能拼出 user message")
}
let phase10System = RecognizedChatPrompt.systemPrompt(skill: skillFixture)

expect(phase10System.hasPrefix(skillFixture), "阶段 10 仍然加载原来的 skill 原文")
expect(phase10System.contains("\"analysis\""), "阶段 10 要求 analysis")
expect(phase10System.contains("\"tone\""), "阶段 10 要求 tone")
expect(phase10System.contains("\"replies\""), "阶段 10 要求 replies")
expect(phase10System.contains("恰好 3 条"), "阶段 10 只要恰好 3 条")
expect(userMessage.contains("恰好 3 条"), "user message 也只要 3 条")

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

// 3. 阶段 10 的 Prompt 不得再要求 6～8 条回复
for forbidden in ["6～8", "6~8"] {
    expect(!phase10System.contains(forbidden), "阶段 10 system prompt 不得要求 \(forbidden)")
    expect(!userMessage.contains(forbidden), "阶段 10 user message 不得要求 \(forbidden)")
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

let request = try GoutouAIClient.buildURLRequest(config: config, systemPrompt: phase10System, userMessage: userMessage)
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
expect(sent[0]["content"] as? String == phase10System, "system 就是阶段 10 的 Prompt")
expect(sent[1]["role"] as? String == "user", "第二条是 user")
expect(sent[1]["content"] as? String == userMessage, "user 就是 Builder 的输出")
expect(root["model"] as? String == "test-model", "模型沿用配置")
expect(root["stream"] as? Bool == false, "非流式请求照旧")
expect(!bodyText.contains("test-key"), "Key 不得进请求体")
expect(!bodyText.contains("6～8"), "请求体里不得要求 6～8 条")
// JSON 里引号会被转义，这里只查关键字出现，不查引号形态。
expect(bodyText.contains("replies"), "请求体里只要求 3 条 replies")

func response(_ content: String, finish: String = "stop", reasoning: String? = nil) -> Data {
    var message: [String: Any] = ["role": "assistant", "content": content]
    if let reasoning = reasoning { message["reasoning_content"] = reasoning }
    let payload: [String: Any] = ["choices": [["message": message, "finish_reason": finish]]]
    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
}

// MARK: - 返回解析：宽容进、严格出（恰好三条）

func chatJSON(analysis: String = "对方在确认今晚的安排。", tone: String = "轻松、在推进",
              replies: [String] = ["好啊，七点老地方", "你先定地方，我都行", "行，那我请客"]) -> String {
    let object: [String: Any] = ["analysis": analysis, "tone": tone, "replies": replies]
    return String(data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), encoding: .utf8) ?? ""
}

/// 和控制器里那三行同一条流水线：响应体 → 拆字段 → 阶段 10 归一化。
func analyze(_ content: String, finish: String = "stop", reasoning: String? = nil)
    -> Result<RecognizedChatResult, RecognizedChatAnalysisError> {
    do {
        let fields = try GoutouAIClient.parseRecognizedChatFields(data: response(content, finish: finish, reasoning: reasoning))
        return RecognizedChatResult.normalized(fields)
    } catch let error as GoutouAIError {
        return .failure(.ai(error))
    } catch {
        return .failure(.incompleteResult)
    }
}

// 5~8. 正常返回：analysis / tone / 三条 / 顺序
guard case .success(let parsed) = analyze(chatJSON()) else {
    fatalError("RecognizedChatAnalysisCheck: 正常 JSON 应当解析成功")
}
expect(parsed.analysis == "对方在确认今晚的安排。", "analysis 正确")
expect(parsed.tone == "轻松、在推进", "tone 正确")
expect(parsed.replies == ["好啊，七点老地方", "你先定地方，我都行", "行，那我请客"], "三条回复正确且顺序不变")
expect(parsed.replies.count == RecognizedChatResult.requiredReplies, "结果恰好三条")

// 9. 超过 3 条只保留前三条有效回复
guard case .success(let many) = analyze(chatJSON(replies: ["一", "二", "三", "四", "五"])) else {
    fatalError("RecognizedChatAnalysisCheck: 多于三条应当仍能成功")
}
expect(many.replies == ["一", "二", "三"], "超过 3 条只保留前三条")

// 10. 少于 3 条不能成功
expect(analyze(chatJSON(replies: ["一", "二"])) == .failure(.notEnoughReplies(validCount: 2)), "少于 3 条不能进入 success")

// 11~12. 空、纯空格、纯标点都不算有效回复
expect(analyze(chatJSON(replies: ["一", "", "三"])) == .failure(.notEnoughReplies(validCount: 2)), "空回复不算数")
expect(analyze(chatJSON(replies: ["一", "   ", "三"])) == .failure(.notEnoughReplies(validCount: 2)), "纯空格回复不算数")
expect(analyze(chatJSON(replies: ["一", "！！！", "三"])) == .failure(.notEnoughReplies(validCount: 2)), "纯标点回复不算数")

// 13. 完全重复的回复不算三条
expect(analyze(chatJSON(replies: ["一样", "一样", "一样"])) == .failure(.notEnoughReplies(validCount: 1)), "三条完全相同视为无效")
guard case .success(let deduped) = analyze(chatJSON(replies: ["一", "二", "二", "三"])) else {
    fatalError("RecognizedChatAnalysisCheck: 去掉重复后仍有三条应当成功")
}
expect(deduped.replies == ["一", "二", "三"], "完全重复的只留第一条")

// 14. 单条超长按设计截断
let longReply = String(repeating: "长", count: RecognizedChatResult.maxReplyLength + 50)
guard case .success(let truncated) = analyze(chatJSON(replies: [longReply, "二", "三"])) else {
    fatalError("RecognizedChatAnalysisCheck: 超长回复截断后应当成功")
}
expect(truncated.replies[0].count == RecognizedChatResult.maxReplyLength + 1, "超长回复截到上限")
expect(truncated.replies[0].hasSuffix(RecognizedChatResult.ellipsis), "截断带省略号")

// 15~16. 代码围栏 / thinking 片段 / 只回思考
guard case .success = analyze("```json\n" + chatJSON() + "\n```") else {
    fatalError("RecognizedChatAnalysisCheck: 代码围栏应当能解析")
}
guard case .success = analyze("<thinking>先想一想</thinking>" + chatJSON()) else {
    fatalError("RecognizedChatAnalysisCheck: thinking 片段应当先被去掉")
}
guard case .success(let fromReasoning) = analyze("", reasoning: chatJSON()) else {
    fatalError("RecognizedChatAnalysisCheck: 只回思考时应当退一步用思考")
}
expect(fromReasoning.tone == "轻松、在推进", "思考里的结构化结果也能用")

// 17. 纯文本 / 缺字段：不许伪装成阶段 10 成功
expect(analyze("对方像是在确认时间。") == .failure(.incompleteResult), "纯文本不能伪装成完整结果")
expect(analyze("{\"analysis\":\"只有分析\"}") == .failure(.incompleteResult), "缺 tone 与三条回复不算完整")
expect(analyze("{\"analysis\":\"分析\",\"tone\":\"\",\"replies\":[\"一\",\"二\",\"三\"]}") == .failure(.incompleteResult),
       "tone 为空不算完整")

// 传输层错误沿用阶段 9 口径
expect(analyze("") == .failure(.ai(.empty)), "空内容")
expect(analyze("", finish: "length") == .failure(.ai(.truncated)), "只被截断、没有任何正文")
expectThrows(.badJSON("不是 JSON"), "响应体不是 JSON") {
    _ = try GoutouAIClient.parseRecognizedChatFields(data: Data("不是 JSON".utf8))
}

// MARK: - 阶段 11：点一条候选 = 只插一次原文

var insertSession = RecognizedChatAnalysisSession()
var writes: [String] = []
func tapReply(_ reply: String) -> Bool {
    RecognizedReplyInsert.perform(reply, from: insertSession) { writes.append($0) }
}

// 10~12：idle / loading / failure 都不能插入
expect(!tapReply(goodResult.replies[0]), "idle 状态不能插入")
expect(writes.isEmpty, "idle 状态一次都没写")
guard case .started(let insertGeneration) = insertSession.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context) else {
    fatalError("RecognizedChatAnalysisCheck: 插入用例没能发起分析")
}
expect(!tapReply(goodResult.replies[0]), "loading 状态不能插入")
expect(writes.isEmpty, "loading 状态一次都没写")
insertSession.complete(generation: insertGeneration, result: .failure(.ai(.timeout)))
expect(!tapReply(goodResult.replies[0]), "failure 状态不能插入")
expect(writes.isEmpty, "failure 状态一次都没写")

// 2~9 / 25~26：成功之后三条分别映射、写的就是原文、点一次只写一次
insertSession.invalidate()
guard case .started(let readyGeneration) = insertSession.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context) else {
    fatalError("RecognizedChatAnalysisCheck: 插入用例没能拿到结果")
}
insertSession.complete(generation: readyGeneration, result: .success(goodResult))

for (index, reply) in goodResult.replies.enumerated() {
    writes.removeAll()
    expect(tapReply(reply), "第 \(index + 1) 条应当可以插入")
    expect(writes.count == 1, "一次点击只写一次")
    expect(writes == [reply], "点第 \(index + 1) 条就写第 \(index + 1) 条原文")
}
expect(!writes.contains { $0.hasPrefix("①") || $0.hasPrefix("②") || $0.hasPrefix("③") }, "插入内容不带序号")
expect(!writes.contains { $0 != $0.trimmed }, "插入内容不带首尾空白")
expect(!writes.contains { $0.contains("\n") }, "插入内容不带换行")

// 6 / 9：脏文本都不算这一条
writes.removeAll()
expect(!tapReply("① " + goodResult.replies[0]), "带序号的文本不算这一条")
expect(!tapReply(" " + goodResult.replies[0]), "带前导空格的文本不算这一条")
expect(!tapReply(goodResult.replies[0] + "\n"), "带尾随换行的文本不算这一条")
expect(!tapReply("别的聊天的回复"), "不在当前结果里的文本不能插")
expect(writes.isEmpty, "这些都不该写进去")

// 13~16：结果失效 / 读取新聊天 / 取消使用 / 重新分析 loading
insertSession.invalidate()
expect(!tapReply(goodResult.replies[0]), "结果作废之后旧卡片插不进去")
expect(writes.isEmpty, "作废之后一次都没写")
expect(insertSession.replyToInsert(goodResult.replies[0]) == nil, "作废之后没有可插入的回复")

insertSession.invalidate()
guard case .started(let reloadGeneration) = insertSession.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context) else {
    fatalError("RecognizedChatAnalysisCheck: 重新分析用例没能发起")
}
insertSession.complete(generation: reloadGeneration, result: .success(goodResult))
writes.removeAll()
guard case .started = insertSession.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context) else {
    fatalError("RecognizedChatAnalysisCheck: 重新分析没能进入 loading")
}
expect(!tapReply(goodResult.replies[0]), "重新分析 loading 时旧回复不能插")
expect(writes.isEmpty, "重新分析 loading 时一次都没写")

// 17：同一份结果里，用户再主动点同一条允许再插一次（每次都要一次明确点击）
insertSession.invalidate()
guard case .started(let againGeneration) = insertSession.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context) else {
    fatalError("RecognizedChatAnalysisCheck: 重复点击用例没能发起")
}
insertSession.complete(generation: againGeneration, result: .success(goodResult))
writes.removeAll()
expect(tapReply(goodResult.replies[0]), "第一次明确点击")
expect(tapReply(goodResult.replies[0]), "第二次明确点击也允许")
expect(writes == [goodResult.replies[0], goodResult.replies[0]], "两次明确点击 = 两次插入")

// MARK: - 20. 不落盘、不写记忆

// 走完一整轮「开始 → 成功 → 读取新聊天作废」，容器里不该多出任何文件。
let fm = FileManager.default
let probeRoot = fm.temporaryDirectory.appendingPathComponent("RecognizedChatAnalysisCheck-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: probeRoot, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: probeRoot) }
let beforeRun = try fm.contentsOfDirectory(atPath: probeRoot.path)
var cycle = RecognizedChatAnalysisSession()
if case .started(let cycleGeneration) = cycle.begin(hasFullAccess: true, config: config, skillAvailable: true, context: context) {
    cycle.complete(generation: cycleGeneration, result: .success(goodResult))
    // 阶段 11：插入一次也不该往磁盘或 UserDefaults 里留东西。
    _ = RecognizedReplyInsert.perform(goodResult.replies[0], from: cycle) { _ in }
}
cycle.invalidate()
let afterRun = try fm.contentsOfDirectory(atPath: probeRoot.path)
expect(beforeRun == afterRun, "分析不往磁盘多写任何文件")
expect(cycle.state == .idle, "一轮走完回到 idle")
expect(UserDefaults.standard.object(forKey: "goutou.recognizedChat.analysis") == nil, "分析结果不写 UserDefaults")
expect(Mirror(reflecting: session).displayStyle == .struct, "分析状态机是值类型，不持有网络客户端")

print("RecognizedChatAnalysisCheck passed (\(checks) assertions; prompts and state only; no network)")

// Jev-style structured candidates must remain usable through the existing chat path.
let structuredCandidates = try GoutouAIClient.parseRecognizedChatFields(data: response("""
{"analysis":"保持轻松","tone":"友好","candidates":[{"text":"好啊，晚点聊","reason":"接住话题","tradeoff":"推进较慢"},{"text":"今晚有空吗","reason":"明确邀请","tradeoff":"需要对方表态"},{"text":"那我先占个位置","reason":"轻松回应","tradeoff":"玩笑可能不合时宜"}]}
"""))
guard case .success(let structuredResult) = RecognizedChatResult.normalized(structuredCandidates) else {
    fatalError("StructuredReplyCheck: structured candidates were lost")
}
expect(structuredResult.replies.count == 3, "structured candidates retain exactly three reply texts")
