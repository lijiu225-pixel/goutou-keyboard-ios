import Foundation

/// 与 Android `GoutouInputMethodService.dictionary` 一字不差的词库（20 条），
/// 外加一层九键真正需要的「数字串 → 候选」索引。
///
/// 为什么必须加这层索引：Android 版是拿多击出来的**字母**去精确查表，
/// 但同一个键上的相邻字母（i 和 h 都在 4 键）必须隔 650ms 才能分开，
/// 正常速度打字几乎必然把字母拼错，于是候选常年是空的。
/// iOS 这边改成九键的标准做法：**按键序列**（比如 64426）直接查表出「你好」，
/// 多击出来的字母只留作兜底和测试。
enum GoutouDictionary {

    /// 保持顺序：候选按这个顺序出，测试也按这个顺序断言。
    private static let entries: [(pinyin: String, words: [String])] = [
        ("ni", ["你", "尼"]),
        ("hao", ["好", "号"]),
        ("wo", ["我"]),
        ("ta", ["她", "他"]),
        ("shi", ["是", "事"]),
        ("de", ["的", "得"]),
        ("ma", ["吗", "嘛"]),
        ("bu", ["不"]),
        ("ai", ["爱"]),
        ("xiang", ["想"]),
        ("yi", ["一", "意"]),
        ("ge", ["个"]),
        ("zai", ["在"]),
        ("you", ["有"]),
        ("xie", ["谢"]),
        ("xiexie", ["谢谢"]),
        ("nihao", ["你好"]),
        ("women", ["我们"]),
        ("keyi", ["可以"]),
        ("meiguanxi", ["没关系"]),
    ]

    private static let wordsByPinyin: [String: [String]] =
        Dictionary(uniqueKeysWithValues: entries.map { ($0.pinyin, $0.words) })

    private static let wordsByDigits: [String: [String]] = {
        var index: [String: [String]] = [:]
        for entry in entries {
            let key = digits(for: entry.pinyin)
            guard !key.isEmpty else { continue }
            index[key, default: []].append(contentsOf: entry.words)
        }
        return index
    }()

    /// 数字串 → 拼音（键盘顶部提示用）。同一个数字串只保留第一个拼音。
    private static let pinyinByDigits: [String: String] = {
        var index: [String: String] = [:]
        for entry in entries {
            let key = digits(for: entry.pinyin)
            guard !key.isEmpty, index[key] == nil else { continue }
            index[key] = entry.pinyin
        }
        return index
    }()

    private static let digitMap: [Character: Character] = [
        "a": "2", "b": "2", "c": "2",
        "d": "3", "e": "3", "f": "3",
        "g": "4", "h": "4", "i": "4",
        "j": "5", "k": "5", "l": "5",
        "m": "6", "n": "6", "o": "6",
        "p": "7", "q": "7", "r": "7", "s": "7",
        "t": "8", "u": "8", "v": "8",
        "w": "9", "x": "9", "y": "9", "z": "9",
    ]

    /// 拼音 → 九键数字串（nihao → 64426）。
    static func digits(for pinyin: String) -> String {
        String(pinyin.lowercased().compactMap { digitMap[$0] })
    }

    /// 九键按键序列 → 候选词。这是 iOS 这边的主查询。
    static func candidates(forDigits digits: String) -> [String] {
        wordsByDigits[digits] ?? []
    }

    /// Android 那边的精确拼音查询（保留：兜底与冒烟测试还在用）。
    static func candidates(for pinyin: String) -> [String] {
        wordsByPinyin[pinyin] ?? []
    }

    /// 数字串命中的拼音，用来在键盘顶部显示 `64426 · nihao`；没命中返回空串。
    static func pinyinHint(forDigits digits: String) -> String {
        pinyinByDigits[digits] ?? ""
    }

    static var wordCount: Int { entries.count }
}
