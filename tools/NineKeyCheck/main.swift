import Foundation

// 中文九键逻辑的冒烟测试。
//
// 跑法（macOS / CI runner，不需要模拟器）：
//   swiftc -swift-version 5 Keyboard/NineKeyMapper.swift Keyboard/GoutouPinyinTable.swift \
//          Keyboard/NineKeyInputEngine.swift Keyboard/GoutouConfig.swift \
//          Keyboard/GoutouPrompt.swift Keyboard/GoutouSegmentStore.swift \
//          Keyboard/GoutouMemoryStore.swift Keyboard/GoutouAIClient.swift \
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

// 测试用的数字映射（App 里不需要这个方向，词库是按拼音存的）
let testDigitMap: [Character: Character] = [
    "a": "2", "b": "2", "c": "2", "d": "3", "e": "3", "f": "3",
    "g": "4", "h": "4", "i": "4", "j": "5", "k": "5", "l": "5",
    "m": "6", "n": "6", "o": "6", "p": "7", "q": "7", "r": "7", "s": "7",
    "t": "8", "u": "8", "v": "8", "w": "9", "x": "9", "y": "9", "z": "9",
]
func t9(_ pinyin: String) -> String {
    String(pinyin.compactMap { testDigitMap[$0] })
}

print("== 九键词库（从仓库里的 TSV 加载）==")
let repoChars = try? String(contentsOfFile: "Keyboard/pinyin-chars.tsv", encoding: .utf8)
let repoWords = try? String(contentsOfFile: "Keyboard/pinyin-words.tsv", encoding: .utf8)
expect(repoChars != nil && repoWords != nil, "能读到 pinyin-chars.tsv / pinyin-words.tsv")
let table = GoutouPinyinTable()
table.load(charsText: repoChars, wordsText: repoWords)
expect(table.syllableCount > 400, "音节数 > 400（实际 \(table.syllableCount)）")
expect(table.wordKeyCount > 10000, "词条 > 10000（实际 \(table.wordKeyCount)）")

print("== 数字串 → 切拼音 → 候选 ==")
let niCandidates = table.candidates(forDigits: t9("ni"))
expectEqual(niCandidates.first ?? "", "你", "64 首选「你」")
expect(niCandidates.contains("尼"), "64 里有「尼」")
expectEqual(table.candidates(forDigits: t9("nihao")).first ?? "", "你好", "64426 首选「你好」")
expect(table.candidates(forDigits: t9("xihuan")).contains("喜欢"), "944826 里有「喜欢」")
expectEqual(table.candidates(forDigits: t9("chifan")).first ?? "", "吃饭", "244326 首选「吃饭」")
expectEqual(table.candidates(forDigits: t9("jintian")).first ?? "", "今天", "5468426 首选「今天」")
expectEqual(table.candidates(forDigits: t9("meiguanxi")).first ?? "", "没关系", "634482694 首选「没关系」")
expectEqual(table.candidates(forDigits: t9("shenme")).first ?? "", "什么", "743663 首选「什么」")
expectEqual(table.candidates(forDigits: t9("duibuqi")).first ?? "", "对不起", "3842874 首选「对不起」")
expectEqual(table.candidates(forDigits: t9("de")).first ?? "", "的", "33 首选「的」")
expect(table.candidates(forDigits: t9("hao")).contains("好"), "426 里有「好」")
expect(table.candidates(forDigits: "999").isEmpty, "999 切不出拼音，没有候选")
expect(table.candidates(forDigits: "").isEmpty, "空串没有候选")
expect(table.split(Array(t9("nihao"))).contains(["ni", "hao"]), "64426 能切成 ni+hao")

print("== 九键主路径（按数字序列出候选）==")
let engine = NineKeyInputEngine(table: table)
press(engine, "6")
expectEqual(engine.digits, "6", "按一下 6")
expect(!engine.candidates.isEmpty, "单字母音节（呣/嗯）也算候选，不会空着")
press(engine, "4")
expectEqual(engine.digits, "64", "再按 4")
expectEqual(engine.pinyinHint, "", "64 有 mi / ni 两种读法，顶部只显示数字")
expectEqual(engine.candidates.first ?? "", "你", "64 首选「你」")

engine.clear()
press(engine, "7484")
expectEqual(engine.pinyinHint, "qiti", "7484 有能成词的切分（qiti）就显示它")
expectEqual(engine.candidates.first ?? "", "体", "7484 首选候选来自词频最高的字")
engine.clear()

press(engine, "64426")
expectEqual(engine.digits, "64426", "连按 64426")
expectEqual(engine.candidates.first ?? "", "你好", "64426 首选「你好」")
expectEqual(engine.flushText() ?? "", "你好", "空格/标点提交时上屏首候选")
expectEqual(engine.digits, "", "提交后数字序列清空")

print("== 候选点一下直接上屏（不走 flush）==")
press(engine, "96")
expectEqual(engine.candidates.first ?? "", "我", "96 首选「我」")
engine.clear()
expectEqual(engine.digits, "", "清空")
expect(engine.candidates.isEmpty, "清空后没有候选")

print("== 回删边界 ==")
press(engine, "64426")
expect(engine.deleteBackward(), "有数字序列时回删被它吃掉")
expectEqual(engine.digits, "6442", "回删一位")
engine.clear()
expect(!engine.deleteBackward(), "没有数字序列时回删交给正文（返回 false）")

print("== 切不出拼音时的兜底 ==")
press(engine, "999")
expect(engine.candidates.isEmpty, "999 没有候选")
expectEqual(engine.flushText() ?? "", "999", "切不出拼音就原样上屏这串数字")
expectEqual(engine.pinyinHint, "", "没有命中时拼音提示为空")

print("== 2.6/2.7：连续输入的拼音路径 + 人工分词边界 ==")
engine.clear()
press(engine, t9("nihao"))
expectEqual(engine.pinyinHint, "ni'hao", "64426 → ni'hao")
engine.clear()
press(engine, t9("zhong") + t9("guo"))
expectEqual(engine.pinyinHint, "zhong'guo", "zhongguo → zhong'guo")
engine.clear()
press(engine, t9("women"))
expectEqual(engine.pinyinHint, "wo'men", "women → wo'men")

engine.clear()
press(engine, t9("nihao"))
engine.toggleBoundaryAtEnd()
expect(engine.boundaries == [5], "末尾钉一条边界")
engine.toggleBoundaryAtEnd()
expect(engine.boundaries.isEmpty, "同一位置再点一次就取消（手滑能撤）")

engine.clear()
press(engine, t9("ni"))
engine.toggleBoundaryAtEnd()
press(engine, t9("hao"))
expectEqual(engine.digits, t9("nihao"), "钉边界不影响数字串")
expect(engine.boundaries == [2], "边界记在 ni|hao 之间")
expectEqual(engine.digitsDisplay, "64'426", "顶部显示带出分词位置")
expectEqual(engine.candidates.first ?? "", "你好", "带边界时首选仍是「你好」")
expectEqual(engine.pinyinHint, "ni'hao", "带边界时拼音提示")

// 删除跨过边界：人工分词要跟着撤销
engine.deleteBackward()
expectEqual(engine.digits, "6442", "回删一位")
engine.deleteBackward()
engine.deleteBackward()
expectEqual(engine.digits, "64", "删到 64")
engine.deleteBackward()
expectEqual(engine.digits, "6", "删到 6")
expect(engine.boundaries.isEmpty, "删过边界之后人工分词被撤销")

// 重输要同时清掉人工边界
engine.clear()
press(engine, t9("ni"))
engine.toggleBoundaryAtEnd()
press(engine, t9("hao"))
engine.clear()
expect(engine.boundaries.isEmpty, "重输清掉人工分词边界")
expectEqual(engine.digits, "", "重输清掉数字串")

print("== 2.8 可自动化的回归项 ==")
engine.clear()
press(engine, "644263453")           // 连续按 9 下
expectEqual(engine.digits.count, 9, "连续快速点击一个都不丢")
expectEqual(engine.digits, "644263453", "codeBuffer 顺序正确")
engine.deleteBackward()
expectEqual(engine.digits, "64426345", "删一位")
expect(!engine.candidates.isEmpty || engine.digits.count > 0, "删完还能重新计算")
while !engine.digits.isEmpty { engine.deleteBackward() }
expectEqual(engine.digits, "", "连续删除最终清空 composing")
expect(engine.candidates.isEmpty, "清空后没有候选")
expect(!engine.deleteBackward(), "codeBuffer 为空时回删交给宿主输入框")

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

let scratchDefaults = UserDefaults(suiteName: "goutou.check.scratch") ?? .standard
print("== 军师上下文落盘（退出面板 / 键盘被回收都不丢，只有点清空才没）==")
GoutouSegmentStore.clear(from: scratchDefaults)
expect(GoutouSegmentStore.load(from: scratchDefaults).isEmpty, "一开始没有存过就是空的")
let storedSegments = [
    GoutouSegment(speaker: .opponent, text: "睡了吗"),
    GoutouSegment(speaker: .me, text: "刚忙完"),
    GoutouSegment(speaker: .background, text: "我们上周吵过架"),
]
GoutouSegmentStore.save(storedSegments, to: scratchDefaults)
let reloaded = GoutouSegmentStore.load(from: scratchDefaults)
expectEqual(reloaded.count, 3, "读回来还是 3 段")
expectEqual(reloaded.first?.text ?? "", "睡了吗", "第一段内容")
expectEqual(reloaded.last?.speaker.promptLabel ?? "", "背景", "第三段归属")
expectEqual(GoutouPrompt.userMessage(segments: reloaded), GoutouPrompt.userMessage(segments: storedSegments), "读回来拼出来的 prompt 一致")
GoutouSegmentStore.save([], to: scratchDefaults)
expect(GoutouSegmentStore.load(from: scratchDefaults).isEmpty, "手动清空之后就是空的")

print("== 长期档案（记忆）==")
let scratchMemory = UserDefaults(suiteName: "goutou.check.memory") ?? .standard
GoutouMemoryStore.clear(from: scratchMemory)
expect(GoutouMemoryStore.load(from: scratchMemory).isEmpty, "一开始没有记忆")
GoutouMemoryStore.save(["她生日 3 月 5 日", "   ", "我们认识三个月"], to: scratchMemory)
let loadedMemory = GoutouMemoryStore.load(from: scratchMemory)
expectEqual(loadedMemory.count, 2, "空白条目会被丢掉")
expectEqual(loadedMemory.first ?? "", "她生日 3 月 5 日", "第一条内容")

let withMemory = GoutouPrompt.userMessage(
    segments: [GoutouSegment(speaker: .opponent, text: "睡了吗")],
    memory: loadedMemory
)
expect(withMemory.hasPrefix("长期档案（用户自己提供的背景事实，不是本次对话）："), "记忆放在对话前面")
expect(withMemory.contains("- 她生日 3 月 5 日"), "记忆按条目列出")
expect(withMemory.contains("聊天内容：\n对方：睡了吗"), "对话部分照旧")
let withoutMemory = GoutouPrompt.userMessage(segments: [GoutouSegment(speaker: .opponent, text: "嗯")])
expect(!withoutMemory.contains("长期档案"), "没有记忆就不带这一段")
GoutouMemoryStore.clear(from: scratchMemory)
expect(GoutouMemoryStore.load(from: scratchMemory).isEmpty, "清空后为空")

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
expect(prompt.contains("6～8 条") && prompt.contains("覆盖 skill 里写的 2～3 条"), "话术条数在 iOS 这边改成 6～8 条")
expect(prompt.contains("角度要拉开"), "要求话术角度拉开，不要一堆同义改写")
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
{"relationship":"他还在观望。","replies":["1","2","3","4","5","6","7","8","9","10"]}
"""
let cappedResult = try? GoutouAIClient.parseResponse(data: responseData(manyReplies))
expectEqual(cappedResult?.replies.count ?? 0, 8, "给多了只留 8 条")
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
