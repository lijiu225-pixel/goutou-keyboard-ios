import Foundation

/// 一条记忆的得分明细（可解释；只在调试里看，不发给 AI）
struct MemoryScoreBreakdown: Equatable {
    var importance: Double = 0
    var confidence: Double = 0
    var recency: Double = 0
    var confirmed: Double = 0
    var keyword: Double = 0
    var category: Double = 0
    /// 时间衰减系数（6.7）：近期状态越旧越小；长期稳定信息恒为 1
    var decayMultiplier: Double = 1
    /// 这条记忆当前是不是「可能过时」（只标记，不删不归档）
    var isStale: Bool = false
    /// 近义惩罚（1 = 没被罚）
    var redundancyMultiplier: Double = 1

    /// 没算时间衰减 / 近义惩罚之前的原始分
    var rawTotal: Double {
        importance + confidence + recency + confirmed + keyword + category
    }

    var total: Double {
        rawTotal * decayMultiplier * redundancyMultiplier
    }

    func penalized(by multiplier: Double) -> MemoryScoreBreakdown {
        var copy = self
        copy.redundancyMultiplier = multiplier
        return copy
    }
}

struct ScoredMemory {
    let memory: PersonMemory
    let breakdown: MemoryScoreBreakdown
    var score: Double { breakdown.total }
}

struct MemorySelectionResult {
    /// 最终进 Prompt 的那几条（已按分数排好、已过预算）
    let items: [PersonMemory]
    /// 全部候选的得分（含落选的），调试用
    let scored: [ScoredMemory]
    /// 实际占用字符数
    let totalCharacters: Int
    /// 是否走了「筛选兜底」路径
    let usedFallback: Bool

    static let empty = MemorySelectionResult(items: [], scored: [], totalCharacters: 0, usedFallback: false)

    /// 候选里有多少条已经「可能过时」（调试 / 以后的管理页用）
    var staleCount: Int { scored.filter { $0.breakdown.isStale }.count }

    /// 调试用的一行行明细（不要塞进主界面）
    var debugLines: [String] {
        scored.prefix(30).map { entry in
            let detail = entry.breakdown
            let preview = String(entry.memory.content.prefix(18))
            return "「\(preview)」 age=\(Self.two(MemoryDecay.ageDays(of: entry.memory)))天"
                + " decay=\(Self.two(detail.decayMultiplier))"
                + " stale=\(detail.isStale ? "是" : "否")"
                + " raw=\(Self.two(detail.rawTotal))"
                + " final=\(Self.two(entry.score))"
                + " [\(entry.memory.category.rawValue)]"
                + " imp=\(Self.two(detail.importance))"
                + " conf=\(Self.two(detail.confidence))"
                + " rec=\(Self.two(detail.recency))"
                + " kw=\(Self.two(detail.keyword))"
                + " cat=\(Self.two(detail.category))"
                + " x冗余\(Self.two(detail.redundancyMultiplier))"
        }
    }

    /// 调试行里统一保留两位小数
    static func two(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

/// 从一个人的未归档记忆里挑出**和这次聊天最相关的 Top-K 条**。
///
/// 第一版全部本地算：importance / confidence / 时间新鲜度 / 是否确认过 / 关键词重合 / 类别优先。
/// 不做 Embedding、不联网、不改数据库——只读 + 排序。
enum MemorySelector {

    /// 同一轮分析不重复算（键 = 人物 + 聊天 + 记忆版本）。只留一条，不落盘。
    ///
    /// 6.7 起还带上「哪一天」：时间衰减按天变化，跨天必须重算，
    /// 免得昨天缓存的结果今天还拿着用（不要求分钟级失效）。
    /// 也带上 config——换了 Top-K / 预算 / 衰减参数就得重新算。
    private struct CacheKey: Equatable {
        let personID: UUID
        let chat: String
        let memoryVersion: String
        let day: Date
        let config: MemoryRankingConfig
    }
    private static var lastKey: CacheKey?
    private static var lastResult: MemorySelectionResult?

    // MARK: - 入口

    static func select(
        personID: UUID,
        chat: [GoutouSegment] = [],
        task: MemoryTaskType = .current,
        memories: [PersonMemory],
        config: MemoryRankingConfig = .default,
        now: Date = Date()
    ) -> MemorySelectionResult {
        let chatText = chat.map { "\($0.speaker.promptLabel)：\($0.text)" }.joined(separator: "\n")
        let day = Calendar.current.startOfDay(for: now)
        let key = CacheKey(
            personID: personID,
            chat: chatText,
            memoryVersion: memoryVersion(of: memories),
            day: day,
            config: config
        )
        if let lastKey = lastKey, lastKey == key, let cached = lastResult { return cached }

        // 硬性安全：只认这个人的、未归档的、有内容的
        let candidates = memories.filter {
            $0.personID == personID && !$0.archived && !$0.content.trimmed.isEmpty
        }
        guard !candidates.isEmpty else {
            cache(key, .empty)
            return .empty
        }

        let keywords = extractKeywords(from: chatText)
        var scored = candidates.map { memory in
            ScoredMemory(
                memory: memory,
                breakdown: score(memory: memory, keywords: keywords, task: task, config: config, now: now)
            )
        }
        // 同分用 id 兜底，保证结果确定
        scored.sort {
            $0.score == $1.score ? $0.memory.id.uuidString < $1.memory.id.uuidString : $0.score > $1.score
        }

        let baselineSlots = max(1, Int((Double(config.defaultTopK) * config.baselineRatio).rounded()))
        let mainSlots = max(0, config.defaultTopK - baselineSlots)

        // 话题 = 「同类别 + 都命中了本次聊天的关键词」。
        // 说明：措辞完全不同的近义（「工作很忙」vs「经常加班」）本地判不出来，
        // 那种要靠 Embedding（下一阶段）；这里只挡住"一堆同话题记忆霸榜"。
        var pickedTopicCount: [String: Int] = [:]
        func topicKey(of memory: PersonMemory) -> String? {
            matchedKeywords(memory: memory, keywords: keywords).isEmpty ? nil : memory.category.rawValue
        }
        func isTopicFull(_ memory: PersonMemory) -> Bool {
            guard let key = topicKey(of: memory) else { return false }
            return (pickedTopicCount[key] ?? 0) >= config.maxPerTopic
        }
        func isNearDuplicate(_ memory: PersonMemory, against chosen: [ScoredMemory]) -> Bool {
            chosen.contains {
                GoutouMemoryApplier.similarity(memory.content, $0.memory.content) >= config.redundancyThreshold
            }
        }
        func register(_ memory: PersonMemory) {
            guard let key = topicKey(of: memory) else { return }
            pickedTopicCount[key, default: 0] += 1
        }

        // 1) 按分数挑。两种「近义」都降权：
        //    ① 文本高度相似（同一件事换了几个字）
        //    ② 话题聚类——同类别 + 命中同一批聊天关键词（措辞完全不同也算同一话题）
        // 被降权的先放 deferred，不占别人的名额；名额还有剩再补位。
        var picked: [ScoredMemory] = []
        var deferred: [ScoredMemory] = []
        var deferredIDs = Set<UUID>()
        func deferCandidate(_ candidate: ScoredMemory) {
            guard !deferredIDs.contains(candidate.memory.id) else { return }
            deferredIDs.insert(candidate.memory.id)
            deferred.append(ScoredMemory(
                memory: candidate.memory,
                breakdown: candidate.breakdown.penalized(by: config.redundancyPenalty)
            ))
        }
        for candidate in scored {
            guard picked.count < mainSlots else { break }
            if isNearDuplicate(candidate.memory, against: picked) || isTopicFull(candidate.memory) {
                deferCandidate(candidate)
            } else {
                picked.append(candidate)
                register(candidate.memory)
            }
        }

        // 2) 保底：长期高重要度就算关键词没命中也要有位置（但同样不重复占位）
        var selectedIDs = Set(picked.map { $0.memory.id })
        var baseline: [ScoredMemory] = []
        for candidate in scored where baseline.count < baselineSlots {
            guard !selectedIDs.contains(candidate.memory.id), isBaseline(candidate.memory, config: config) else { continue }
            if isNearDuplicate(candidate.memory, against: picked) || isTopicFull(candidate.memory) {
                deferCandidate(candidate)
                continue
            }
            baseline.append(candidate)
            selectedIDs.insert(candidate.memory.id)
            register(candidate.memory)
        }

        // 3) 名额没满：先用「没用过、也不近义」的记忆补位，
        //    最后才轮到被降权的近义记忆（宁可少一条，也不让同话题霸榜）。
        var final = picked + baseline
        for candidate in scored where final.count < config.defaultTopK {
            guard !selectedIDs.contains(candidate.memory.id) else { continue }
            guard !isNearDuplicate(candidate.memory, against: final), !isTopicFull(candidate.memory) else { continue }
            final.append(candidate)
            selectedIDs.insert(candidate.memory.id)
            register(candidate.memory)
        }
        for candidate in deferred where final.count < config.defaultTopK {
            guard !selectedIDs.contains(candidate.memory.id) else { continue }
            final.append(candidate)
            selectedIDs.insert(candidate.memory.id)
        }

        var usedFallback = false
        if final.isEmpty {
            usedFallback = true
            final = fallbackScored(scored, limit: min(3, config.defaultTopK), config: config)
        }
        final.sort {
            $0.score == $1.score ? $0.memory.id.uuidString < $1.memory.id.uuidString : $0.score > $1.score
        }

        // 4) 字符预算：到量就停，**绝不截断一条记忆**
        var items: [PersonMemory] = []
        var characters = 0
        for candidate in final {
            let length = candidate.memory.content.count
            guard characters + length <= config.maxMemoryCharacters else { continue }
            items.append(candidate.memory)
            characters += length
        }

        let result = MemorySelectionResult(
            items: items,
            scored: scored,
            totalCharacters: characters,
            usedFallback: usedFallback
        )
        cache(key, result)
        return result
    }

    /// 兜底：筛选因为任何原因拿不出结果时，退回少量高重要度记忆（主分析绝不能因此崩）。
    static func fallback(
        personID: UUID,
        memories: [PersonMemory],
        limit: Int = 5,
        maxCharacters: Int = MemoryRankingConfig.default.maxMemoryCharacters
    ) -> MemorySelectionResult {
        let candidates = memories
            .filter { $0.personID == personID && !$0.archived && !$0.content.trimmed.isEmpty }
            .sorted {
                $0.importance == $1.importance
                    ? $0.updatedAt > $1.updatedAt
                    : $0.importance > $1.importance
            }
        var items: [PersonMemory] = []
        var characters = 0
        for memory in candidates where items.count < limit {
            let length = memory.content.count
            guard characters + length <= maxCharacters else { continue }
            items.append(memory)
            characters += length
        }
        return MemorySelectionResult(
            items: items,
            scored: items.map { ScoredMemory(memory: $0, breakdown: MemoryScoreBreakdown(importance: Double($0.importance))) },
            totalCharacters: characters,
            usedFallback: true
        )
    }

    // MARK: - 评分

    static func score(
        memory: PersonMemory,
        keywords: Set<String>,
        task: MemoryTaskType,
        config: MemoryRankingConfig,
        now: Date
    ) -> MemoryScoreBreakdown {
        var breakdown = MemoryScoreBreakdown()
        // importance 1…5 → 0…1（不让它单独决定结果）
        let importanceRatio = Double(min(5, max(1, memory.importance)) - 1) / 4.0
        breakdown.importance = config.importanceWeight * importanceRatio
        breakdown.confidence = config.confidenceWeight * GoutouMemoryApplier.clampConfidence(memory.confidence)
        breakdown.recency = config.recencyWeight * recencyRatio(memory: memory, config: config, now: now)
        breakdown.confirmed = config.confirmedWeight * (memory.lastConfirmedAt == nil ? 0 : 1)
        breakdown.keyword = config.keywordWeight * keywordRatio(memory: memory, keywords: keywords)
        breakdown.category = config.categoryWeight * categoryRatio(memory.category, task: task, config: config)
        // 6.7：时间衰减（近期状态越旧分越低；长期稳定信息恒为 1），原始 confidence / importance 不动
        let decay = MemoryDecay.state(for: memory, at: now, config: config.decay)
        breakdown.decayMultiplier = decay.multiplier
        breakdown.isStale = decay.isStale
        return breakdown
    }

    /// 平滑衰减：7 天≈接近满分、30 天中等、90 天较低、更久继续降但不归零。
    /// 时间基准统一走 `MemoryDecay.effectiveDate`（lastConfirmedAt → updatedAt → createdAt）。
    static func recencyRatio(memory: PersonMemory, config: MemoryRankingConfig, now: Date) -> Double {
        let reference = MemoryDecay.effectiveDate(of: memory)
        let days = max(0, now.timeIntervalSince(reference) / 86_400)
        let decay = exp(-days / max(1, config.recencyHalfLifeDays))
        return config.recencyFloor + (1 - config.recencyFloor) * decay
    }

    /// 关键词重合比例（本地版；以后换 Embedding 只动这一个函数）
    static func keywordRatio(memory: PersonMemory, keywords: Set<String>) -> Double {
        let matched = matchedKeywords(memory: memory, keywords: keywords)
        guard !matched.isEmpty else { return 0 }
        return min(1.0, Double(matched.count) / 3.0)
    }

    /// 这条记忆命中了聊天里的哪些关键词（话题聚类也用它）
    static func matchedKeywords(memory: PersonMemory, keywords: Set<String>) -> Set<String> {
        guard !keywords.isEmpty else { return [] }
        let contentKeywords = extractKeywords(from: memory.content)
        return keywords.intersection(contentKeywords)
    }

    static func categoryRatio(_ category: MemoryCategory, task: MemoryTaskType, config: MemoryRankingConfig) -> Double {
        let order = config.categoryPriorities[task] ?? []
        guard let rank = order.firstIndex(of: category) else { return config.categoryUnlistedScore }
        return max(config.categoryUnlistedScore, 1.0 - config.categoryStepPenalty * Double(rank))
    }

    static func isBaseline(_ memory: PersonMemory, config: MemoryRankingConfig) -> Bool {
        if memory.importance >= config.baselineMinImportance { return true }
        let relational: [MemoryCategory] = [.relationship, .importantEvent]
        return relational.contains(memory.category) && memory.importance >= config.baselineRelationMinImportance
    }

    static func fallbackScored(
        _ scored: [ScoredMemory],
        limit: Int,
        config: MemoryRankingConfig
    ) -> [ScoredMemory] {
        scored
            .sorted {
                $0.memory.importance == $1.memory.importance
                    ? $0.memory.updatedAt > $1.memory.updatedAt
                    : $0.memory.importance > $1.memory.importance
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - 关键词（第一版：中文 2-gram + 英文词）

    /// 单独成函数，方便以后整块换成 Embedding。
    static func extractKeywords(from text: String) -> Set<String> {
        var keywords = Set<String>()

        // 英文/数字：按非字母数字切开，太短的丢掉
        for token in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let word = String(token)
            guard word.count >= 3 else { continue }
            keywords.insert(word)
        }

        // 中文：连续汉字段的 2-gram（不需要分词库，够用）
        var run: [Character] = []
        func flushRun() {
            defer { run.removeAll() }
            if run.count == 1, let single = run.first {
                keywords.insert(String(single))
                return
            }
            guard run.count >= 2 else { return }
            for index in 0..<(run.count - 1) {
                keywords.insert(String(run[index...index + 1]))
            }
        }
        for character in text {
            if character.isChineseIdeograph {
                run.append(character)
            } else {
                flushRun()
            }
        }
        flushRun()
        return keywords
    }

    // MARK: - 内部

    private static func memoryVersion(of memories: [PersonMemory]) -> String {
        memories
            .map {
                // 内容也算进版本：6.8 的合并会改内容但不一定动 updatedAt，
                // 不带上内容的话缓存可能还拿着合并前的旧条目。
                "\($0.id.uuidString):\(Int($0.updatedAt.timeIntervalSince1970)):\($0.archived ? 1 : 0)"
                    + ":\($0.content.count):\($0.content.hashValue)"
            }
            .sorted()
            .joined(separator: "|")
    }

    private static func cache(_ key: CacheKey, _ result: MemorySelectionResult) {
        lastKey = key
        lastResult = result
    }
}

extension Character {
    /// 是不是汉字（CJK 基本区）
    var isChineseIdeograph: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}
