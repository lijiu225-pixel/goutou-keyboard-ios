import Foundation

// 中文九键逻辑的冒烟测试。
//
// 跑法（macOS / CI runner，不需要模拟器）：
//   swiftc -swift-version 5 Keyboard/NineKeyMapper.swift Keyboard/GoutouPinyinTable.swift \
//          Keyboard/NineKeyInputEngine.swift Keyboard/GoutouConfig.swift \
//          Keyboard/GoutouPrompt.swift Keyboard/GoutouProfileStore.swift \
//          Keyboard/GoutouMemoryItem.swift Keyboard/GoutouMemoryExtractor.swift \
//          Keyboard/GoutouSegmentStore.swift \
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
expectEqual(engine.pinyinHint, "qi'ti", "7484 有能成词的切分（qi'ti）就按音节显示")
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
GoutouMemoryStore.append("她生日 3 月 5 日", to: scratchMemory)
GoutouMemoryStore.append("   ", to: scratchMemory)
GoutouMemoryStore.append("我们认识三个月", to: scratchMemory)
let loadedMemory = GoutouMemoryStore.load(from: scratchMemory)
expectEqual(loadedMemory.count, 2, "空白条目会被丢掉")
expectEqual(loadedMemory.first?.content ?? "", "她生日 3 月 5 日", "第一条内容")
expect((loadedMemory.first?.category ?? .recentStatus) == .stableFact, "手工加的都算稳定事实")
expect(!(loadedMemory.first?.id.isEmpty ?? true), "每条记忆都有 id")

let withMemory = GoutouPrompt.userMessage(
    segments: [GoutouSegment(speaker: .opponent, text: "睡了吗")],
    memory: loadedMemory.map { $0.content }
)
expect(withMemory.hasPrefix("长期档案（用户自己提供的背景事实，不是本次对话）："), "记忆放在对话前面")
expect(withMemory.contains("- 她生日 3 月 5 日"), "记忆按条目列出")
expect(withMemory.contains("聊天内容：\n对方：睡了吗"), "对话部分照旧")
let withoutMemory = GoutouPrompt.userMessage(segments: [GoutouSegment(speaker: .opponent, text: "嗯")])
expect(!withoutMemory.contains("长期档案"), "没有记忆就不带这一段")
GoutouMemoryStore.clear(from: scratchMemory)
expect(GoutouMemoryStore.load(from: scratchMemory).isEmpty, "清空后为空")

print("== 第六阶段：多人独立档案（数据完全隔离）==")
let scratchProfiles = UserDefaults(suiteName: "goutou.check.profiles") ?? .standard
scratchProfiles.removeObject(forKey: GoutouProfileStore.storageKey)
scratchProfiles.removeObject(forKey: GoutouProfileStore.legacySegmentsKey)
scratchProfiles.removeObject(forKey: GoutouProfileStore.legacyMemoryKey)

// 老版本的单份数据 → 迁移成「默认」档案
let legacySegments = [GoutouSegment(speaker: .opponent, text: "睡了吗")]
scratchProfiles.set(try! JSONEncoder().encode(legacySegments), forKey: GoutouProfileStore.legacySegmentsKey)
scratchProfiles.set(try! JSONEncoder().encode(["她生日 3 月 5 日"]), forKey: GoutouProfileStore.legacyMemoryKey)
let migrated = GoutouProfileStore.loadBook(from: scratchProfiles)
expectEqual(migrated.profiles.count, 1, "老数据迁移成一个档案")
expectEqual(migrated.profiles[0].name, "默认", "默认档案的名字")
expectEqual(migrated.profiles[0].segments.count, 1, "老的上下文搬进来了")
expectEqual(migrated.profiles[0].memory.first?.content ?? "", "她生日 3 月 5 日", "老的记忆搬进来了")
expect(scratchProfiles.data(forKey: GoutouProfileStore.legacySegmentsKey) == nil, "迁移完删掉旧键，不会重复读")

// 新建第二个人：不能看到第一个人的任何数据
let second = GoutouProfileStore.create(name: "老王", in: scratchProfiles)
expectEqual(GoutouProfileStore.loadBook(from: scratchProfiles).profiles.count, 2, "现在有两个档案")
expect(GoutouSegmentStore.load(from: scratchProfiles).isEmpty, "新档案的上下文是空的（不串）")
expect(GoutouMemoryStore.load(from: scratchProfiles).isEmpty, "新档案的记忆是空的（不串）")

// 给老王加料
GoutouSegmentStore.save([GoutouSegment(speaker: .me, text: "老王的消息")], to: scratchProfiles)
GoutouMemoryStore.append("老王爱喝酒", to: scratchProfiles)
GoutouProfileStore.updateActive({ $0.summary = GoutouSavedSummary(headline: "老王在试探你", replies: ["在"], savedAt: Date()) }, in: scratchProfiles)
expectEqual(GoutouSegmentStore.load(from: scratchProfiles).first?.text ?? "", "老王的消息", "当前档案读到自己那份")
expectEqual(GoutouProfileStore.activeProfile(from: scratchProfiles).summary?.headline ?? "", "老王在试探你", "AI 总结也按人存")

// 切回默认：拿到的必须是默认那份
let firstID = GoutouProfileStore.loadBook(from: scratchProfiles).profiles.first { $0.id != second.id }?.id ?? ""
GoutouProfileStore.select(id: firstID, in: scratchProfiles)
expectEqual(GoutouSegmentStore.load(from: scratchProfiles).first?.text ?? "", "睡了吗", "切回默认拿到自己那份上下文")
expectEqual(GoutouMemoryStore.load(from: scratchProfiles).first?.content ?? "", "她生日 3 月 5 日", "记忆同样隔离")
expect(GoutouProfileStore.activeProfile(from: scratchProfiles).summary == nil, "默认档案没有老王的总结")

// 改名 / 删除（最后一个不许删）
GoutouProfileStore.rename(id: second.id, to: "老王（同事）", in: scratchProfiles)
expect(GoutouProfileStore.loadBook(from: scratchProfiles).profiles.contains { $0.name == "老王（同事）" }, "改名生效")
GoutouProfileStore.delete(id: second.id, in: scratchProfiles)
expectEqual(GoutouProfileStore.loadBook(from: scratchProfiles).profiles.count, 1, "删掉一个档案")
GoutouProfileStore.delete(id: firstID, in: scratchProfiles)
expectEqual(GoutouProfileStore.loadBook(from: scratchProfiles).profiles.count, 1, "只剩一个时删不掉（保证总有当前人物）")

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

print("== 宽容解析：接口返回的 JSON 各种走样都要能认（这次修的就是这条）==")
func summary(_ content: String) -> GoutouResult? {
    try? GoutouAIClient.parseResponse(data: responseData(content))
}
// 1) 前后有废话
let withProse = summary("好的，这是分析结果：{\"relationship\":\"对方在试探你会不会主动。依据……\",\"replies\":[\"在啊\",\"刚忙完\"]} 希望有帮助～")
expectEqual(withProse?.headline ?? "", "对方在试探你会不会主动。", "JSON 前后有废话也能抠出来")
expectEqual(withProse?.replies.count ?? 0, 2, "话术也认出来了")
// 2) 尾逗号
let trailingComma = summary("{\"relationship\":\"他还在观望。\",\"replies\":[\"在\",\"嗯\",],}")
expectEqual(trailingComma?.headline ?? "", "他还在观望。", "尾逗号能修")
expectEqual(trailingComma?.replies.count ?? 0, 2, "尾逗号数组里的条目也在")
// 3) 外面又套了一层
let wrapped = summary("{\"data\":{\"relationship\":\"她想见你。\",\"replies\":[\"走啊\"]}}")
expectEqual(wrapped?.headline ?? "", "她想见你。", "包了一层 data 也认")
// 4) 中文键名
let chineseKeys = summary("{\"关系\":\"她在等你先开口。\",\"回复\":[\"在忙吗\",\"睡了吗\"]}")
expectEqual(chineseKeys?.headline ?? "", "她在等你先开口。", "中文键名也认")
expectEqual(chineseKeys?.replies.first ?? "", "在忙吗", "中文键名的话术也在")
// 5) replies 是一整段字符串
let singleStringReplies = summary("{\"relationship\":\"还行。\",\"replies\":\"在啊\\n刚忙完\\n怎么了\"}")
expectEqual(singleStringReplies?.replies.count ?? 0, 3, "整段字符串按行拆成 3 条")
// 6) content 是分片数组
let partsPayload: [String: Any] = ["choices": [["message": ["content": [["type": "text", "text": "{\"relationship\":\"他在等你。\",\"replies\":[\"在\"]}"]]]]]]
let partsResult = try? GoutouAIClient.parseResponse(data: (try? JSONSerialization.data(withJSONObject: partsPayload)) ?? Data())
expectEqual(partsResult?.headline ?? "", "他在等你。", "content 是分片数组也能拼出来")
// 7) 只回了思考、正文是空的 → 报明确原因，不要含糊的 badJSON
let reasoningOnly: [String: Any] = ["choices": [["finish_reason": "length", "message": ["content": "", "reasoning_content": "让我想想……"]]]]
do {
    _ = try GoutouAIClient.parseResponse(data: (try? JSONSerialization.data(withJSONObject: reasoningOnly)) ?? Data())
    expect(false, "只回思考时应该抛错")
} catch let error as GoutouAIError {
    expect(error == .reasoningOnly(true), "只回思考时给出「被截断」的原因（实际：\(error.message)）")
    expect(error.message.contains("deepseek-chat"), "错误里给出可操作建议（换非推理模型）")
} catch {
    expect(false, "抛出的应该是 GoutouAIError")
}
// 7b) 正文空、但思考里其实混着约定 JSON → 抢救出来，别让用户白等
let salvaged: [String: Any] = [
    "choices": [[
        "finish_reason": "stop",
        "message": [
            "content": "",
            "reasoning_content": "先看这段对话……\n最终答案：{\"relationship\":\"他在发火，先别硬顶。\",\"replies\":[\"先别回\",\"你冷静一下\"]}",
        ],
    ]]
]
let salvagedResult = try? GoutouAIClient.parseResponse(data: (try? JSONSerialization.data(withJSONObject: salvaged)) ?? Data())
expectEqual(salvagedResult?.headline ?? "", "他在发火，先别硬顶。", "思考里混着 JSON 也能抢救出来")
expectEqual(salvagedResult?.replies.count ?? 0, 2, "抢救出来的话术也在")
// 8) 真的不是 JSON 时，错误里要带出开头，方便定位
do {
    _ = try GoutouAIClient.parseResponse(data: responseData("抱歉，我不能帮你分析这段关系。"))
    expect(false, "不是 JSON 时应该抛错")
} catch let error as GoutouAIError {
    expect(error.message.contains("抱歉，我不能帮你分析"), "错误信息里带出返回开头（实际：\(error.message)）")
} catch {
    expect(false, "抛出的应该是 GoutouAIError")
}

print("== 真机上遇到的那类返回：字段里带未转义引号 / 裸换行 / 被截断（按字段切片兜底）==")
// 1) 值里有没转义的引号（严格 JSON 必失败）
let messy = summary("{ \"meaning\": \"1. 对方: 他说\"干死你\"了\\n2. 对方: k\", \"relationship\": \"他在发火，先别硬顶。后面是依据\", \"replies\": [\"先别回\", \"你冷静一下\"], \"reason\": \"...\" }")
expectEqual(messy?.headline ?? "", "他在发火，先别硬顶。", "字段里带未转义引号也能捞出来")
expectEqual(messy?.replies.count ?? 0, 2, "话术也在")
// 2) 字符串里混进裸换行（控制字符，严格 JSON 也不认）
let rawNewline = summary("{\n \"meaning\": \"第一行\n第二行\",\n \"relationship\": \"他在观望。\",\n \"replies\": [\"在\"]\n}")
expectEqual(rawNewline?.headline ?? "", "他在观望。", "裸换行也能捞出来")
expectEqual(rawNewline?.replies.first ?? "", "在", "裸换行时话术也在")
// 3) 被截断，但已经给了 relationship
let cutOff = summary("{ \"meaning\": \"1. 对方: 我那你号护我朋友了\", \"relationship\": \"他在发火，先别硬顶。\", \"repl")
expectEqual(cutOff?.headline ?? "", "他在发火，先别硬顶。", "截断了也把已经给全的字段用上")
// 4) 截断到只剩半句 meaning，且 finish_reason=length → 明确说被截断
let onlyMeaning: [String: Any] = [
    "choices": [["finish_reason": "length", "message": ["content": "{ \"meaning\": \"1. 对方: 我那你号护我朋友了\\n2. 对方: k"]]]
]
do {
    _ = try GoutouAIClient.parseResponse(data: (try? JSONSerialization.data(withJSONObject: onlyMeaning)) ?? Data())
    expect(false, "截断到没有可用字段时应该抛错")
} catch let error as GoutouAIError {
    expect(error == .truncated, "明确报「被截断」而不是含糊的空内容（实际：\(error.message)）")
} catch {
    expect(false, "抛出的应该是 GoutouAIError")
}

print("== 自动归纳：MemoryExtractor 解析（AI 只能改不能删）==")
let extractorReply = """
{"operations":[
 {"op":"ADD","content":"她在互联网公司做运营","category":"stable_fact","importance":4,"confidence":0.9},
 {"op":"UPDATE","targetID":"abc","content":"她生日是 3 月 5 日","category":"stable_fact","importance":4,"confidence":0.9},
 {"op":"MERGE","targetID":"def","content":"他养了只猫","category":"偏好","importance":2,"confidence":0.6},
 {"op":"IGNORE","targetID":"abc"},
 {"op":"DELETE","targetID":"abc"},
 {"op":"UPDATE","content":"没带 target 的更新应该被丢掉"}
]}
"""
let parsedOps = GoutouMemoryExtractor.parse(extractorReply) ?? []
expectEqual(parsedOps.count, 4, "只认 ADD/UPDATE/MERGE/IGNORE，UPDATE 必须带 target，DELETE 直接丢")
expect(parsedOps.first?.operation == .add, "第一条是 ADD")
expect((parsedOps.first?.category ?? .recentStatus) == .stableFact, "英文分类解析")
expectEqual(parsedOps.count > 1 ? (parsedOps[1].targetID ?? "") : "", "abc", "UPDATE 的 targetID")
expect(parsedOps.count > 2 ? parsedOps[2].operation == .merge : false, "MERGE 认出来")
expect((parsedOps.count > 2 ? parsedOps[2].category : .stableFact) == .preference, "中文分类也认（偏好）")
expect(parsedOps.count > 3 ? parsedOps[3].operation == .ignore : false, "IGNORE 认出来")
expect(GoutouMemoryExtractor.parse("这不是 JSON") == nil, "解析不了 → nil（调用方一个字都不改）")
expectEqual(GoutouMemoryExtractor.parse("{\"operations\":[]}")?.count ?? 1, 0, "空操作是合法的（记忆不动）")
expect(
    (GoutouMemoryExtractor.parse("{\"operations\":[{\"op\":\"ADD\",\"content\":\"她在加班\",\"category\":\"近况\"}]}")?.first?.category ?? .stableFact) == .recentStatus,
    "近期状态能认出来（和稳定事实分开存）"
)

print("== 自动归纳：只动当前人物 / 去重 / 更新 / 重启仍在 ==")
let scratchAuto = UserDefaults(suiteName: "goutou.check.auto") ?? .standard
scratchAuto.removeObject(forKey: GoutouProfileStore.storageKey)
scratchAuto.removeObject(forKey: GoutouProfileStore.legacySegmentsKey)
scratchAuto.removeObject(forKey: GoutouProfileStore.legacyMemoryKey)

let autoA = GoutouProfileStore.loadBook(from: scratchAuto).profiles[0]
let autoB = GoutouProfileStore.create(name: "B", in: scratchAuto)
GoutouProfileStore.select(id: autoB.id, in: scratchAuto)
GoutouMemoryStore.append("B 的旧记忆", to: scratchAuto)
GoutouProfileStore.select(id: autoA.id, in: scratchAuto)
GoutouMemoryStore.append("她生日是 3 月 5 日", to: scratchAuto)

let aItems = GoutouMemoryStore.load(from: scratchAuto)
let birthdayID = aItems.first?.id ?? ""
let bItemID = GoutouProfileStore.loadBook(from: scratchAuto)
    .profiles.first { $0.id == autoB.id }?.memory.first?.id ?? ""

let ops: [GoutouMemoryCandidate] = [
    GoutouMemoryCandidate(operation: .add, targetID: nil, content: "她在互联网公司做运营",
                          category: .stableFact, importance: 4, confidence: 0.9),
    GoutouMemoryCandidate(operation: .update, targetID: birthdayID, content: "她生日是 3 月 5 日（已确认）",
                          category: .stableFact, importance: 4, confidence: 0.95),
    GoutouMemoryCandidate(operation: .update, targetID: bItemID, content: "偷改 B 的记忆",
                          category: .stableFact, importance: 5, confidence: 1.0),
    GoutouMemoryCandidate(operation: .add, targetID: nil, content: "她生日是3月5日",
                          category: .stableFact, importance: 3, confidence: 0.8),
]
let appliedMemory = GoutouMemoryApplier.apply(ops, to: aItems, personID: autoA.id)
expectEqual(appliedMemory.changed, 2, "只算「新增 + 真更新」两条（越权 + 重复都不算）")
GoutouMemoryStore.replaceAll(appliedMemory.items, from: scratchAuto)

let aAfter = GoutouMemoryStore.load(from: scratchAuto)
expectEqual(aAfter.count, 2, "A 从 1 条变 2 条：重复的没有新增")
expect(aAfter.contains { $0.content.contains("互联网公司") }, "新事实进来了")
expect(aAfter.contains { $0.content.contains("已确认") }, "老记忆被更新，而不是新加一条")
expect(!aAfter.contains { $0.content.contains("她生日是3月5日") }, "近似重复没有变成独立条目")
expect(aAfter.allSatisfy { $0.personID == autoA.id }, "A 的记忆归属都还是 A")

GoutouProfileStore.select(id: autoB.id, in: scratchAuto)
let bAfter = GoutouMemoryStore.load(from: scratchAuto)
expectEqual(bAfter.count, 1, "B 还是 1 条")
expectEqual(bAfter.first?.content ?? "", "B 的旧记忆", "B 的内容没被动过")
expect(!bAfter.contains { $0.content.contains("互联网公司") }, "A 的信息没有串到 B")
expectEqual(bAfter.first?.personID ?? "", autoB.id, "B 的记忆归属还是 B")

// 重启：重新从盘里读（新的 loadBook 调用），记忆还在
let afterRestart = GoutouProfileStore.loadBook(from: scratchAuto)
    .profiles.first { $0.id == autoB.id }?.memory ?? []
expectEqual(afterRestart.count, 1, "重启后 B 的记忆还在")
let aAfterRestart = GoutouProfileStore.loadBook(from: scratchAuto)
    .profiles.first { $0.id == autoA.id }?.memory ?? []
expectEqual(aAfterRestart.count, 2, "重启后 A 的记忆还在")
expect(aAfterRestart.allSatisfy { !$0.id.isEmpty }, "每条都带稳定 id")
expect(aAfterRestart.contains { $0.updatedAt > $0.createdAt }, "被更新的那条留了 updatedAt")

print("")
if failures == 0 {
    print("全部通过：\(checks) 项检查")
} else {
    print("失败 \(failures) / \(checks) 项")
    exit(1)
}
