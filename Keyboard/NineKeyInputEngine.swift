import Foundation

/// 中文九键的输入状态机：只维护 composing 串和上一次按键状态。
///
/// 对应 Android 里散在 `GoutouInputMethodService` 上的那几段逻辑
/// （`composing` / `lastNineKey` / `flushComposing` / `clearComposing` / `deleteOnce` 的拼音部分）。
/// 抽出来是因为它们跟平台无关，iOS 键盘扩展可以直接用，也方便在 macOS 上跑冒烟测试。
final class NineKeyInputEngine {

    /// 正在拼的拼音字母串（对应 Android 的 `composing`）。
    private(set) var composing: String = ""

    /// 上一次按键状态（对应 Android 的 `lastNineKey`）。
    private(set) var lastState: NineKeyMapper.State?

    /// Android `handleKey` 里 `key in '2'..'9'` 那一支。
    func appendDigit(_ key: Character, timestamp: TimeInterval) {
        let result = NineKeyMapper.next(text: composing, key: key, previous: lastState, timestamp: timestamp)
        composing = result.text
        lastState = result.state
    }

    /// Android `deleteOnce()`：有 composing 就吃一个字；返回 true 表示吃掉了，没轮到删正文。
    @discardableResult
    func deleteBackward() -> Bool {
        guard !composing.isEmpty else { return false }
        composing.removeLast()
        lastState = nil
        return true
    }

    /// Android `clearComposing()`。
    func clear() {
        composing = ""
        lastState = nil
    }

    /// Android `flushComposing()`：有 composing 就取词库首候选，取不到就原样上屏。
    /// 返回 nil 表示本来就没有待上屏的拼音。
    func flushText() -> String? {
        guard !composing.isEmpty else { return nil }
        let text = GoutouDictionary.firstWord(for: composing) ?? composing
        clear()
        return text
    }
}
