import Foundation

// 中文九键逻辑的冒烟测试。
//
// 跑法（macOS / CI runner，不需要模拟器）：
//   swiftc -swift-version 5 Keyboard/NineKeyMapper.swift Keyboard/GoutouDictionary.swift \
//          Keyboard/NineKeyInputEngine.swift tools/NineKeyCheck/main.swift -o /tmp/ninekeycheck
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

print("")
if failures == 0 {
    print("全部通过：\(checks) 项检查")
} else {
    print("失败 \(failures) / \(checks) 项")
    exit(1)
}
