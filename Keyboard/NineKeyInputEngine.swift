import Foundation

/// 中文九键的输入状态：只维护按过的数字序列。
///
/// 为什么不是字母串：九键的标准做法是按**数字序列**查候选（按 6 4 4 2 6 → 64426 → 你好）。
/// 之前照搬 Android 的"多击生成拼音字母 + 字母精确匹配"，按 6 4 得到的是字母 `mg`，
/// 词库里永远匹配不到，表现出来就是"能打出拼音但不出汉字"。
///
/// 多击循环本身留在 `NineKeyMapper` 里（作为 Android 口径参照），当前输入路径不走它。
final class NineKeyInputEngine {

    /// 按过的数字键序列，例如 `64426`。
    private(set) var digits: String = ""

    /// 当前数字序列能出的候选词。
    var candidates: [String] {
        GoutouDictionary.candidates(forDigits: digits)
    }

    /// 当前数字序列对应的拼音（界面顶部显示用），没有命中就是空串。
    var pinyinHint: String {
        GoutouDictionary.pinyinHint(forDigits: digits)
    }

    /// 只在九键的 2…9 上调用；1 和 0 是独立动作，不进入数字序列。
    func appendDigit(_ key: Character) {
        guard !NineKeyMapper.group(for: key).isEmpty else { return }
        digits.append(key)
    }

    /// 有数字序列就吃一位；返回 true 表示被它吃掉了，没轮到删正文。
    @discardableResult
    func deleteBackward() -> Bool {
        guard !digits.isEmpty else { return false }
        digits.removeLast()
        return true
    }

    func clear() {
        digits = ""
    }

    /// 把当前数字序列提交出去：有候选取首候选，没有就原样上屏这串数字。
    /// 返回 nil 表示本来就没有待上屏的内容。
    func flushText() -> String? {
        guard !digits.isEmpty else { return nil }
        let text = candidates.first ?? digits
        clear()
        return text
    }
}
