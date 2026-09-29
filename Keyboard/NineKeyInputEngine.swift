import Foundation

/// 中文九键的输入状态：只维护按过的数字序列。
///
/// 为什么不是字母串：九键的标准做法是按**数字序列**查候选（按 6 4 4 2 6 → 64426 → 你好）。
/// 之前照搬 Android 的"多击生成拼音字母 + 字母精确匹配"，按 6 4 得到的是字母 `mg`，
/// 词库里永远匹配不到，表现出来就是"能打出拼音但不出汉字"。
///
/// 多击循环本身留在 `NineKeyMapper` 里（作为 Android 口径参照），当前输入路径不走它。
final class NineKeyInputEngine {

    private let table: GoutouPinyinTable

    init(table: GoutouPinyinTable = .shared) {
        self.table = table
    }

    /// 按过的数字键序列，例如 `64426`。
    private(set) var digits: String = ""

    /// 人工分词边界：数字串下标，表示「在这个位置之前断开」。
    /// 由「分词」键写入，用于强制音节边界（`64|426` 不许重新组合成别的切法）。
    private(set) var boundaries: Set<Int> = []

    /// 顶部显示的输入串：人工边界处补一个 `'`（`64'426`）。
    var digitsDisplay: String {
        guard !boundaries.isEmpty else { return digits }
        var result = ""
        for (index, character) in digits.enumerated() {
            if boundaries.contains(index), index > 0, index < digits.count { result.append("'") }
            result.append(character)
        }
        return result
    }

    /// 当前数字序列能出的候选词。
    var candidates: [String] {
        table.candidates(forDigits: digits, boundaries: boundaries)
    }

    /// 顶部那行显示的拼音提示（`64426 · nihao`）。没有能成词的切分就返回空串。
    ///
    /// 单音节输入只在毫无歧义时才显示（7484 只有 shui 一种读法 → 显示；
    /// 64 可能是 mi 也可能是 ni → 只显示数字，免得显示的和首选候选对不上）。
    var pinyinHint: String {
        guard !digits.isEmpty else { return "" }
        let splits = table.split(Array(digits), boundaries: boundaries)
        // 能成词的切分优先：人工分词只约束「在哪儿断」，不决定读法
        for segments in splits where segments.count > 1 {
            if table.hasWord(segments.joined()) { return segments.joined(separator: "'") }
        }
        if !boundaries.isEmpty, let first = splits.first {
            return first.joined(separator: "'")
        }
        let singles = Set(splits.filter { $0.count == 1 }.compactMap { $0.first })
        if singles.count == 1 { return singles.first ?? "" }
        return ""
    }

    /// 「分词」键：在当前输入末尾钉一条边界；同一个位置再点一次取消。
    func toggleBoundaryAtEnd() {
        guard !digits.isEmpty else { return }
        if boundaries.contains(digits.count) {
            boundaries.remove(digits.count)
        } else {
            boundaries.insert(digits.count)
        }
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
        // 越界的边界跟着撤销（删过头就把那条人工分词也去掉）
        boundaries = boundaries.filter { $0 < digits.count }
        return true
    }

    func clear() {
        digits = ""
        boundaries = []
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
