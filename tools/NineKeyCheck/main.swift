import Foundation

// 中文九键逻辑的冒烟测试。
//
// 跑法（macOS / CI runner，不需要模拟器）：
//   swiftc -swift-version 5 Keyboard/NineKeyMapper.swift Keyboard/GoutouDictionary.swift \
//          Keyboard/NineKeyInputEngine.swift Keyboard/GoutouConfig.swift \
//          Keyboard/GoutouPrompt.swift Keyboard/GoutouAIClient.swift \
//          tools/NineKeyCheck/main.swift -o /tmp/ninekeycheck
//   /tmp/ninekeycheck
//
// 覆盖：数字序列查候选、候选上屏、回删边界、词库兜底，
// 以及 NineKeyMapper（Android 多击循环口径参照）本身没被改坏。

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

func expectEqual(_ actual: String, _ expected: String, _ label: String) {
    expect(actual == expected, "\(label) → 期望「\(expected)」，实际「\(actual)」")
}

func expectEqual(_ actual: Int, _ expected: Int, _ label: String) {
    expect(actual == expected, "\(label) → 期望 \(expected)，实际 \(actual)")
}

/// 依次按下一串数字键。
func press(_ engine: NineKeyInputEngine, _ keys: String) {
    for key in keys {
        engine.appendDigit(key)
    }
}

print("== 拼音 → 数字键序列 ==")
expectEqual(GoutouDictionary.digits(for: "ni"), "64", "ni")
expectEqual(GoutouDictionary.digits(for: "hao"), "426", "hao")
expectEqual(GoutouDictionary.digits(for: "nihao"), "64426", "nihao")
expectEqual(GoutouDictionary.digits(for: "women"), "96636", "women")
expectEqual(GoutouDictionary.digits(for: "meiguanxi"), "634482694", "meiguanxi")

print("== 九键主路径：按数字序列出候选（这次修的就是这条）==")
let engine = NineKeyInputEngine()
press(engine, "6")
expectEqual(engine.digits, "6", "按一下 6")
expectEqual(engine.candidates.count, 0, "词库里没有单字母拼音，先不出候选")
press(engine, "4")
expectEqual(engine.digits, "64", "再按 4")
expectEqual(engine.pinyinHint, "ni", "64 推出的拼音")
expectEqual(engine.candidates.joined(separator: ","), "你,尼", "64 出候选「你」「尼」")

press(engine, "426")
expectEqual(engine.digits, "64426", "继续按 426")
expectEqual(engine.candidates.joined(separator: ","), "你好", "64426 出候选「你好」")
expectEqual(engine.flushText() ?? "", "你好", "空格/标点提交时上屏首候选")
expectEqual(engine.digits, "", "提交后数字序列清空")

print("== 候选点一下直接上屏（不走 flush）==")
press(engine, "96")
expectEqual(engine.candidates.joined(separator: ","), "我", "96 出候选「我」")
engine.clear()
expectEqual(engine.digits, "", "清空")
expectEqual(engine.candidates.count, 0, "清空后没有候选")

print("== 回删边界 ==")
press(engine, "64426")
expect(engine.deleteBackward(), "有数字序列时回删被它吃掉")
expectEqual(engine.digits, "6442", "回删一位")
expectEqual(engine.candidates.count, 0, "6442 没有候选")
engine.clear()
expect(!engine.deleteBackward(), "没有数字序列时回删交给正文（返回 false）")

print("== 词库兜底 ==")
expectEqual(GoutouDictionary.wordCount, 20, "词库条数与 Android 一致")
expectEqual(GoutouDictionary.candidates(for: "ni").joined(separator: ","), "你,尼", "精确拼音查询保留")
expectEqual(GoutouDictionary.candidates(forDigits: "634482694").joined(separator: ","), "没关系", "四字母以上的词条")
expectEqual(GoutouDictionary.candidates(forDigits: "999").count, 0, "查不到的数字串返回空")
press(engine, "999")
expectEqual(engine.flushText() ?? "", "999", "词库没有命中就原样上屏这串数字")
expectEqual(GoutouDictionary.pinyinHint(forDigits: "999"), "", "没有命中时拼音提示为空")

print("== 1 和 0 不进数字序列 ==")
engine.clear()
press(engine, "1")
expectEqual(engine.digits, "", "1 是「，」动作，不算一位数字")
press(engine, "0")
expectEqual(engine.digits, "", "0 是空格动作，不算一位数字")

print("== NineKeyMapper：Android 多击循环口径参照没被改坏 ==")
expectEqual(NineKeyMapper.group(for: "2"), "abc", "2")
expectEqual(NineKeyMapper.group(for: "7"), "pqrs", "7")
expectEqual(NineKeyMapper.group(for: "9"), "wxyz", "9")
expectEqual(NineKeyMapper.group(for: "1"), "", "1 没有字母组")
let cycle = NineKeyMapper.next(text: "", key: "6", previous: nil, timestamp: 0)
expectEqual(cycle.text, "m", "6 第一下")
let cycle2 = NineKeyMapper.next(text: cycle.text, key: "6", previous: cycle.state, timestamp: 0.3)
expectEqual(cycle2.text, "n", "650ms 内再按 6 循环到 n")
let cycle3 = NineKeyMapper.next(text: "m", key: "6", previous: cycle.state, timestamp: 5.0)
expectEqual(cycle3.text, "mm", "超过 650ms 另起一个字母")

print("== 军师配置：导出 / 导入 ==")
let sample = GoutouConfig(baseURL: "https://api.example.com/v1", model: "gpt-4o-mini", apiKey: "sk-test-1234")
let exported = sample.exportText
expect(exported.hasPrefix(GoutouConfig.marker), "导出文本第一行是版本标记")
expectEqual(GoutouConfig.parse(importText: exported)?.baseURL ?? "", "https://api.example.com/v1", "导入回来的 Base URL")
expectEqual(GoutouConfig.parse(importText: exported)?.model ?? "", "gpt-4o-mini", "导入回来的 Model")
expectEqual(GoutouConfig.parse(importText: exported)?.apiKey ?? "", "sk-test-1234", "导入回来的 Key")
expect(GoutouConfig.parse(importText: "随便一段别的文本") == nil, "剪贴板里不是配置文本时不认领")
expect(GoutouConfig.parse(importText: GoutouConfig.marker + "\nbase=\nmodel=\nkey=x") == nil, "缺 Base URL 时不算有效配置")
expectEqual(sample.summary, "gpt-4o-mini · ****1234", "配置摘要里 key 只露最后 4 位")

print("== 请求地址拼接 ==")
expectEqual(GoutouConfig(baseURL: "https://a.com/v1", model: "m", apiKey: "").chatCompletionsURL?.absoluteString ?? "", "https://a.com/v1/chat/completions", "只填到 /v1")
expectEqual(GoutouConfig(baseURL: "https://a.com/v1/", model: "m", apiKey: "").chatCompletionsURL?.absoluteString ?? "", "https://a.com/v1/chat/completions", "结尾多一个斜杠")
expectEqual(GoutouConfig(baseURL: "https://a.com/v1/chat/completions", model: "m", apiKey: "").chatCompletionsURL?.absoluteString ?? "", "https://a.com/v1/chat/completions", "直接填完整地址不重复拼")
expect(GoutouConfig(baseURL: "不是网址", model: "m", apiKey: "").chatCompletionsURL == nil, "非法地址拼不出 URL")
expect(GoutouConfig(baseURL: "a.com/v1", model: "m", apiKey: "").chatCompletionsURL == nil, "缺 http(s) 的地址不算数")

print("== 请求体 ==")
let request = try? GoutouAIClient.buildURLRequest(config: sample, systemPrompt: "SYS", userMessage: "USER")
expectEqual(request?.httpMethod ?? "", "POST", "请求方法")
expectEqual(request?.value(forHTTPHeaderField: "Authorization") ?? "", "Bearer sk-test-1234", "带上 Bearer key")
let bodyObject = ((try? JSONSerialization.jsonObject(with: request?.httpBody ?? Data())) as? [String: Any]) ?? [:]
expectEqual(bodyObject["model"] as? String ?? "", "gpt-4o-mini", "请求体里的 model")
expect(bodyObject["stream"] as? Bool == false, "非流式")
let sentMessages = bodyObject["messages"] as? [[String: Any]] ?? []
expectEqual(sentMessages.count, 2, "system + user 共两条")
expectEqual((sentMessages.first?["content"] as? String) ?? "", "SYS", "第一条是 system")

print("== prompt 口径 ==")
let prompt = GoutouPrompt.systemPrompt(skill: "【人格】")
expect(prompt.hasPrefix("【人格】"), "skill 原文放在最前面")
expect(prompt.contains("当前任务：分析她/他说什么意思。回复风格：自然。"), "写死的任务/风格与 Android 默认值一致")
expect(prompt.contains("不超过 20 字"), "补了 relationship 第一句 ≤20 字的要求")
expect(prompt.contains("meaning") && prompt.contains("replies"), "四字段契约仍然在")
expect(prompt.contains("4～6 条") && prompt.contains("覆盖 skill 里写的 2～3 条"), "话术条数在 iOS 这边改成 4～6 条")
let composed = GoutouPrompt.userMessage(segments: [
    GoutouSegment(speaker: .opponent, text: "你昨天不是说好了吗"),
    GoutouSegment(speaker: .me, text: "临时有事"),
    GoutouSegment(speaker: .background, text: "我们上周吵过架"),
])
expectEqual(composed, "聊天内容：\n对方：你昨天不是说好了吗\n我：临时有事\n背景：我们上周吵过架", "上下文拼成 skill 认得的格式")

print("== 一行判断 ==")
expectEqual(GoutouPrompt.headline(fromRelationship: "对方在试探你会不会主动。后面是依据。"), "对方在试探你会不会主动。", "只取第一句")
expectEqual(GoutouPrompt.headline(fromRelationship: String(repeating: "很", count: 30)), String(repeating: "很", count: 20) + "…", "超 20 字截断加省略号")
expectEqual(GoutouPrompt.headline(fromRelationship: "   \n  "), "", "空内容返回空串")

print("== 解析模型返回 ==")
func responseData(_ content: String) -> Data {
    let payload: [String: Any] = ["choices": [["message": ["content": content]]]]
    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
}
let goodJSON = """
{"meaning":"...","relationship":"对方在试探你会不会主动。依据是……",\
"replies":["在啊","刚忙完，怎么了","你找我有事？","晚点说也行"],"reason":"..."}
"""
let parsedResult = try? GoutouAIClient.parseResponse(data: responseData("```json\n" + goodJSON + "\n```"))
expectEqual(parsedResult?.headline ?? "", "对方在试探你会不会主动。", "带代码围栏也能解析，并取到一行判断")
expectEqual(parsedResult?.replies.count ?? 0, 4, "4 条话术全留下")
expectEqual(parsedResult?.replies.first ?? "", "在啊", "第一条话术")
let manyReplies = """
{"relationship":"他还在观望。","replies":["1","2","3","4","5","6","7","8"]}
"""
let cappedResult = try? GoutouAIClient.parseResponse(data: responseData(manyReplies))
expectEqual(cappedResult?.replies.count ?? 0, 6, "给多了只留 6 条")
let errorBody = (try? JSONSerialization.data(withJSONObject: ["error": ["message": "invalid api key"]])) ?? Data()
do {
    _ = try GoutouAIClient.parseResponse(data: errorBody)
    expect(false, "接口报错时应该抛错")
} catch let error as GoutouAIError {
    expect(error.message.contains("invalid api key"), "接口报错会带出原文")
} catch {
    expect(false, "抛出的应该是 GoutouAIError")
}
do {
    _ = try GoutouAIClient.parseResponse(data: responseData("这不是 JSON"))
    expect(false, "模型没返回 JSON 时应该抛错")
} catch {
    expect(true, "模型没返回 JSON 时抛错")
}

print("")
if failures == 0 {
    print("全部通过：\(checks) 项检查")
} else {
    print("失败 \(failures) / \(checks) 项")
    exit(1)
}
