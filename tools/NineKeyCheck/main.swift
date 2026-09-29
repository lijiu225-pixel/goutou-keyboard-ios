import Foundation

// 中文九键逻辑的冒烟测试。
//
// 跑法（macOS / CI runner，不需要模拟器）：
//   swiftc Keyboard/NineKeyMapper.swift Keyboard/GoutouDictionary.swift \
//          Keyboard/NineKeyInputEngine.swift tools/NineKeyCheck/main.swift -o /tmp/ninekeycheck
//   /tmp/ninekeycheck
//
// 只覆盖这一阶段真正要保证的东西：多击循环、词库候选、上屏文本、回删边界。

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

print("== 数字键字母组（对齐 Android NineKeyMapper.groups）==")
expectEqual(NineKeyMapper.group(for: "2"), "abc", "2")
expectEqual(NineKeyMapper.group(for: "7"), "pqrs", "7")
expectEqual(NineKeyMapper.group(for: "9"), "wxyz", "9")
expectEqual(NineKeyMapper.group(for: "1"), "", "1 没有字母组")

print("== 多击循环与 650ms 窗口 ==")
let engine = NineKeyInputEngine()
engine.appendDigit("6", timestamp: 0)
expectEqual(engine.composing, "m", "按一次 6")
engine.appendDigit("6", timestamp: 0.3)
expectEqual(engine.composing, "n", "300ms 内再按 6")
engine.appendDigit("6", timestamp: 0.6)
expectEqual(engine.composing, "o", "再按 6")
engine.appendDigit("6", timestamp: 0.9)
expectEqual(engine.composing, "m", "再按 6，回到组首")

engine.appendDigit("7", timestamp: 1.2)
expectEqual(engine.composing, "mp", "换键追加 7 的首字母")
engine.appendDigit("7", timestamp: 1.4)
expectEqual(engine.composing, "mq", "7 循环到 q")
engine.appendDigit("7", timestamp: 1.6)
expectEqual(engine.composing, "mr", "7 循环到 r")
engine.appendDigit("7", timestamp: 1.8)
expectEqual(engine.composing, "ms", "7 循环到 s")
engine.appendDigit("7", timestamp: 2.0)
expectEqual(engine.composing, "mp", "7 是四字母组，第五下回到 p")

engine.clear()
engine.appendDigit("6", timestamp: 10.0)
engine.appendDigit("6", timestamp: 11.0)
expectEqual(engine.composing, "mm", "超过 650ms 另起一个字母")

print("== 打出 ni / nihao，候选与上屏 ==")
engine.clear()
engine.appendDigit("6", timestamp: 20.0)
engine.appendDigit("6", timestamp: 20.1)
expectEqual(engine.composing, "n", "6 两下得到 n")
engine.appendDigit("4", timestamp: 20.2)
engine.appendDigit("4", timestamp: 20.3)
engine.appendDigit("4", timestamp: 20.4)
expectEqual(engine.composing, "ni", "4 三下得到 i，拼成 ni")
expectEqual(GoutouDictionary.candidates(for: "ni").joined(separator: ","), "你,尼", "ni 的候选词")
expectEqual(engine.flushText() ?? "", "你", "flush 上屏首候选")
expectEqual(engine.composing, "", "flush 之后 composing 清空")

engine.clear()
// n i | 等过 650ms 再按 4 起 h（i 和 h 都在 4 键上）
engine.appendDigit("6", timestamp: 21.0)
engine.appendDigit("6", timestamp: 21.1)
engine.appendDigit("4", timestamp: 21.2)
engine.appendDigit("4", timestamp: 21.3)
engine.appendDigit("4", timestamp: 21.4)
engine.appendDigit("4", timestamp: 22.4)
engine.appendDigit("4", timestamp: 22.5)
engine.appendDigit("2", timestamp: 22.6)
engine.appendDigit("6", timestamp: 22.7)
engine.appendDigit("6", timestamp: 22.8)
engine.appendDigit("6", timestamp: 22.9)
expectEqual(engine.composing, "nihao", "连打出 nihao")
expectEqual(GoutouDictionary.candidates(for: "nihao").joined(separator: ","), "你好", "nihao 的候选词")
expectEqual(engine.flushText() ?? "", "你好", "nihao 上屏")

print("== 回删边界 ==")
engine.clear()
engine.appendDigit("6", timestamp: 30.0)
engine.appendDigit("4", timestamp: 30.1)
expectEqual(engine.composing, "mg", "两个字母")
expect(engine.deleteBackward(), "有拼音时回删被 composing 吃掉")
expectEqual(engine.composing, "m", "回删一个字母")
expect(engine.deleteBackward(), "再回删一个")
expectEqual(engine.composing, "", "拼音删空")
expect(!engine.deleteBackward(), "没有拼音时回删交给正文（返回 false）")

print("== 词库兜底 ==")
engine.clear()
engine.appendDigit("9", timestamp: 40.0)
engine.appendDigit("7", timestamp: 40.1)
expectEqual(engine.composing, "wp", "拼出词库里没有的字母串")
expectEqual(engine.flushText() ?? "", "wp", "词库没有就原样上屏")
expectEqual(GoutouDictionary.wordCount, 20, "词库条数与 Android 一致")
expectEqual(GoutouDictionary.candidates(for: "meiguanxi").joined(separator: ","), "没关系", "四字母以上的词条")
expectEqual(GoutouDictionary.candidates(for: "zzz").count, 0, "查不到的词条返回空")

print("")
if failures == 0 {
    print("全部通过：\(checks) 项检查")
} else {
    print("失败 \(failures) / \(checks) 项")
    exit(1)
}
