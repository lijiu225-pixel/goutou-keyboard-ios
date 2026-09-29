import Foundation

/// 九键拼音词库：两份打进 bundle 的 TSV（见 `tools/fetch-pinyin-data.py`）。
///
/// - `pinyin-chars.tsv`：`ni\t你呢尼泥拟逆…` —— 单个音节 → 候选汉字（按词频排序）
/// - `pinyin-words.tsv`：`nihao\t你好` —— 整串拼音 → 候选词（按词频排序）
///
/// 九键的匹配过程：**按键数字串 → 切成所有可能的拼音组合 → 查表出候选**。
/// 比如 64426 能切成 ni+hao，于是出「你好」；切不出来就没有候选。
/// 这是九键输入法的标准做法，比按单字拼音精确匹配可用的多。
final class GoutouPinyinTable {

    /// 键盘里用的那一份（懒加载，第一次访问时读 bundle）。
    static let shared = GoutouPinyinTable.loadFromBundle()

    private(set) var syllableSet: Set<String> = []
    /// 数字串 → 可能对应的音节（26 既可能是 an 也可能是 ao）
    private(set) var syllablesByDigits: [String: [String]] = [:]
    private(set) var charsTextBySyllable: [String: String] = [:]
    /// 多音字里非首选读法的字（打 shui 时「说 shuì」要排在「水」后面）
    private(set) var secondaryCharsBySyllable: [String: String] = [:]
    private(set) var wordsByPinyin: [String: [String]] = [:]
    /// 全局常用度：字 → 名次（越小越常用），用来把不同音节的候选字混排。
    private(set) var charRank: [Character: Int] = [:]
    private(set) var isLoaded = false

    private(set) var syllableCount = 0
    private(set) var wordKeyCount = 0

    init() {}

    static func loadFromBundle() -> GoutouPinyinTable {
        let table = GoutouPinyinTable()
        table.load(
            charsText: bundleText(resource: "pinyin-chars"),
            wordsText: bundleText(resource: "pinyin-words")
        )
        return table
    }

    private static func bundleText(resource: String) -> String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "tsv") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 加载

    /// 没显式 `load` 过就自己去 bundle 里读（`init()` 出来的实例走这条路）。
    func loadIfNeeded() {
        guard !isLoaded else { return }
        load(
            charsText: GoutouPinyinTable.bundleText(resource: "pinyin-chars"),
            wordsText: GoutouPinyinTable.bundleText(resource: "pinyin-words")
        )
    }

    func load(charsText: String?, wordsText: String?) {
        guard !isLoaded else { return }
        isLoaded = true

        if let charsText = charsText {
            for line in charsText.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let syllable = String(parts[0])
                guard !syllable.isEmpty else { continue }
                if syllable.hasPrefix("#") {
                    // `#rank` 行：全局常用度排序，不参与音节索引
                    var index = 0
                    for character in parts[1] {
                        if charRank[character] == nil { charRank[character] = index }
                        index += 1
                    }
                    continue
                }
                syllableSet.insert(syllable)
                let groups = parts[1].split(separator: "|", omittingEmptySubsequences: false)
                charsTextBySyllable[syllable] = groups.first.map(String.init) ?? ""
                secondaryCharsBySyllable[syllable] = groups.count > 1 ? String(groups[1]) : ""
                if let digits = GoutouPinyinTable.digits(of: syllable) {
                    syllablesByDigits[digits, default: []].append(syllable)
                }
            }
        }
        syllableCount = syllableSet.count

        if let wordsText = wordsText {
            for line in wordsText.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = String(parts[0])
                guard !key.isEmpty else { continue }
                let words = parts[1].split(separator: "|").map(String.init).filter { !$0.isEmpty }
                if !words.isEmpty { wordsByPinyin[key] = words }
            }
        }
        wordKeyCount = wordsByPinyin.count
    }

    // MARK: - 候选

    /// 按键数字串 → 候选词/字。词优先，然后是最后一个音节的单字（方便一个字一个字打）。
    /// `boundaries` 是用户用「分词」键强制指定的音节边界（数字串下标），切分不许跨过它。
    func candidates(forDigits digits: String, boundaries: Set<Int> = [], limit: Int = 12) -> [String] {
        loadIfNeeded()
        guard isLoaded, !digits.isEmpty, limit > 0 else { return [] }

        let splits = split(Array(digits), boundaries: boundaries)
        guard !splits.isEmpty else { return [] }

        var result: [String] = []
        var seen = Set<String>()
        func add(_ items: [String]) {
            for item in items where result.count < limit && !seen.contains(item) {
                seen.insert(item)
                result.append(item)
            }
        }

        // 词：跨切分汇总后按「频次档位」排。不这样排，打 244326 会因为先切出
        // chi+dao 而把「赤道」摆在「吃饭」前面。
        var words: [(bucket: Int, word: String)] = []
        var wordSeen = Set<String>()
        for segments in splits {
            for token in wordsByPinyin[segments.joined()] ?? [] {
                guard let decoded = GoutouPinyinTable.decode(token), !wordSeen.contains(decoded.word) else { continue }
                wordSeen.insert(decoded.word)
                words.append(decoded)
            }
        }
        words.sort { $0.bucket > $1.bucket }

        // 单字：把每种切分的末音节候选字汇到一起，按**全局常用度**排序。
        // 这样 64（mi / ni 都成立）先出「你」而不是先出一串「米密秘」。
        var pool: [(secondary: Int, character: Character)] = []
        var poolSeen = Set<Character>()
        for segments in splits {
            let syllable = segments.count == 1 ? segments[0] : (segments.last ?? "")
            let groups = [(0, charsTextBySyllable[syllable] ?? ""), (1, secondaryCharsBySyllable[syllable] ?? "")]
            for (flag, text) in groups {
                for character in text where !poolSeen.contains(character) {
                    poolSeen.insert(character)
                    pool.append((flag, character))
                }
            }
        }
        pool.sort {
            $0.secondary == $1.secondary
                ? (charRank[$0.character] ?? Int.max) < (charRank[$1.character] ?? Int.max)
                : $0.secondary < $1.secondary
        }
        let poolChars = pool.map { String($0.character) }

        // 单音节输入（64、426）先把字摆出来——用户这时候要的是单字；
        // 多音节输入（64426）先摆词——这时候要的是「你好」。
        if (splits.first?.count ?? 0) == 1 {
            add(poolChars)
            add(words.map(\.word))
        } else {
            add(words.map(\.word))
            add(poolChars)
        }
        return result
    }

    /// 词条存的是「词 + 一位频次档位」，这里拆开。
    static func decode(_ token: String) -> (bucket: Int, word: String)? {
        guard token.count > 1, let last = token.last, let bucket = last.wholeNumberValue else { return nil }
        return (bucket, String(token.dropLast()))
    }

    /// 给测试和调试用：这个音节有没有候选字。
    func hasSyllable(_ syllable: String) -> Bool {
        loadIfNeeded()
        return syllableSet.contains(syllable)
    }

    /// 这个整串拼音有没有对应词。
    func hasWord(_ pinyin: String) -> Bool {
        loadIfNeeded()
        return wordsByPinyin[pinyin] != nil
    }

    /// 把一个数字串切成所有可能的拼音组合（最多 maxResults 种，够用且不会爆）。
    ///
    /// 例：`64426` → `["ni", "hao"]`；`26` 既可以切成 `an` 也可以切成 `ao`，两种都算。
    /// **长的音节优先**：不这样排，`嗯/呣` 这种单字母音节（m/n/o）会把
    /// `meiguanxi` 切成 `m+di+gu+a+m+xi`，把结果额度用光，真正的分段反而排不进来。
    func split(_ digits: [Character], maxResults: Int = 64, boundaries: Set<Int> = []) -> [[String]] {
        guard isLoaded else { return [] }
        var results: [[String]] = []
        var stack: [String] = []
        let cuts = boundaries.filter { $0 > 0 && $0 < digits.count }.sorted()

        func walk(_ index: Int) {
            guard results.count < maxResults else { return }
            guard index < digits.count else {
                results.append(stack)
                return
            }
            // 人工分词边界：这个音节最多只能长到下一个边界
            let limit = cuts.first(where: { $0 > index }) ?? digits.count
            var chunk = ""
            var cursor = index
            var reachable: [(end: Int, options: [String])] = []
            // 拼音音节最长 6 个字母（zhuang / chuang）
            while cursor < digits.count, cursor < limit, cursor - index < 7 {
                chunk.append(digits[cursor])
                cursor += 1
                if let options = syllablesByDigits[chunk] {
                    reachable.append((cursor, options))
                }
            }
            for entry in reachable.reversed() {
                for option in entry.options {
                    stack.append(option)
                    walk(entry.end)
                    stack.removeLast()
                    if results.count >= maxResults { return }
                }
            }
        }
        walk(0)
        return results
    }

    /// 拼音 → 九键数字（和 Android 那份 group 表一致，ü 写作 v 走 8 键）。
    static func digits(of pinyin: String) -> String? {
        var result = ""
        for character in pinyin.lowercased() {
            guard let digit = digitMap[character] else { return nil }
            result.append(digit)
        }
        return result.isEmpty ? nil : result
    }

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
}
