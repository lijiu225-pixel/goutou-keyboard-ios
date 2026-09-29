import Foundation

/// 与 Android `GoutouInputMethodService.dictionary` 一字不差的词库（20 条）。
///
/// 这层就是「跨平台可复用的候选词库逻辑」：两边共用同一份口径，
/// 以后换大词库（或接 RIME）也只需要动这一处，不用改输入逻辑。
enum GoutouDictionary {

    private static let words: [String: [String]] = [
        "ni": ["你", "尼"],
        "hao": ["好", "号"],
        "wo": ["我"],
        "ta": ["她", "他"],
        "shi": ["是", "事"],
        "de": ["的", "得"],
        "ma": ["吗", "嘛"],
        "bu": ["不"],
        "ai": ["爱"],
        "xiang": ["想"],
        "yi": ["一", "意"],
        "ge": ["个"],
        "zai": ["在"],
        "you": ["有"],
        "xie": ["谢"],
        "xiexie": ["谢谢"],
        "nihao": ["你好"],
        "women": ["我们"],
        "keyi": ["可以"],
        "meiguanxi": ["没关系"],
    ]

    /// Android: `dictionary[composing]` —— 精确匹配拼音串。
    static func candidates(for pinyin: String) -> [String] {
        words[pinyin] ?? []
    }

    /// Android `flushComposing()` 用的首候选。
    static func firstWord(for pinyin: String) -> String? {
        words[pinyin]?.first
    }

    static var wordCount: Int { words.count }
}
