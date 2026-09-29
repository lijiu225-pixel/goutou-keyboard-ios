import Foundation

/// 与 Android `NineKeyMapper.kt` 逐行对应的九键多击逻辑。
///
/// 纯逻辑、只依赖 Foundation，所以 iOS 键盘扩展和 macOS 上的命令行冒烟测试
/// （`tools/NineKeyCheck/main.swift`）可以共用同一份实现。
///
/// 注意：iOS 的输入路径现在已经改成"按数字序列查候选"（见 `NineKeyInputEngine`），
/// `group(for:)` 仍在使用；`next()` 保留为 Android 多击循环的口径参照与回归基线。
///
/// 语义（与 Android 完全一致）：
/// - 同一个键在 650ms 内连按 → 在该键的字母组里循环（2 → A,B,C → A…）
/// - 换键，或距上次按键超过 650ms → 在末尾追加该键字母组的第一个字母
enum NineKeyMapper {

    /// Android 里的 `State`：记住上次按的是哪个键、什么时候按的、替换的是第几个字符。
    struct State: Equatable {
        let key: Character
        let timestamp: TimeInterval
        let replacedIndex: Int
    }

    struct Result {
        let text: String
        let state: State
    }

    /// Android 里的 650L。
    static let cycleWindow: TimeInterval = 0.65

    private static let groups: [Character: String] = [
        "2": "abc",
        "3": "def",
        "4": "ghi",
        "5": "jkl",
        "6": "mno",
        "7": "pqrs",
        "8": "tuv",
        "9": "wxyz",
    ]

    /// 九键上每个数字键对应的字母组（用来显示键上的小字）。
    static func group(for key: Character) -> String {
        groups[key] ?? ""
    }

    static func next(text: String, key: Character, previous: State?, timestamp: TimeInterval) -> Result {
        guard let group = groups[key], !group.isEmpty else {
            return Result(text: text, state: State(key: key, timestamp: timestamp, replacedIndex: text.count))
        }

        let canCycle = previous?.key == key
            && timestamp - (previous?.timestamp ?? 0) <= cycleWindow
            && !text.isEmpty

        guard canCycle, let previous = previous else {
            // 新的一次按键：追加本键字母组的首字母。
            return Result(
                text: text + String(group[group.startIndex]),
                state: State(key: key, timestamp: timestamp, replacedIndex: text.count)
            )
        }

        let characters = Array(text)
        // Android: previous.replacedIndex.coerceIn(0, text.lastIndex)
        let index = min(max(previous.replacedIndex, 0), characters.count - 1)
        let current = characters[index]
        // Android: group.indexOf(current).coerceAtLeast(0) —— 找不到就按 0 处理
        let currentOffset = group.firstIndex(of: current).map { group.distance(from: group.startIndex, to: $0) } ?? 0
        let letters = Array(group)
        let nextLetter = letters[(currentOffset + 1) % letters.count]

        var updated = characters
        updated[index] = nextLetter

        return Result(
            text: String(updated),
            state: State(key: key, timestamp: timestamp, replacedIndex: index)
        )
    }
}
