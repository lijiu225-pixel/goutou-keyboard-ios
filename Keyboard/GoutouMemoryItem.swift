import Foundation

/// 记忆分类。稳定事实和近期状态**分开存**（`isStable`），
/// 近期状态会随时间失效，展示和清理时可以区别对待。
enum GoutouMemoryCategory: String, Codable, CaseIterable {
    case stableFact = "stable_fact"
    case preference
    case relationship
    case communicationStyle = "communication_style"
    case importantEvent = "important_event"
    case recentStatus = "recent_status"

    /// 界面上用的短标签
    var label: String {
        switch self {
        case .stableFact: return "事实"
        case .preference: return "偏好"
        case .relationship: return "关系"
        case .communicationStyle: return "沟通"
        case .importantEvent: return "事件"
        case .recentStatus: return "近况"
        }
    }

    /// 稳定事实（长期有效）还是近期状态（会过期）
    var isStable: Bool {
        self != .recentStatus
    }

    /// 宽松认一下：模型可能回英文枚举，也可能直接回中文标签
    static func from(_ text: String) -> GoutouMemoryCategory {
        let key = text.trimmed.lowercased()
        if let exact = GoutouMemoryCategory(rawValue: key) { return exact }
        switch key {
        case "事实", "稳定事实", "stable", "fact": return .stableFact
        case "偏好", "喜好", "prefer": return .preference
        case "关系", "relationship_status": return .relationship
        case "沟通", "沟通习惯", "communication", "style": return .communicationStyle
        case "事件", "重要事件", "event": return .importantEvent
        case "近况", "近期状态", "状态", "recent", "status": return .recentStatus
        default: return .stableFact
        }
    }
}

/// 一条人物记忆。
struct GoutouMemoryItem: Codable, Equatable, Identifiable {
    var id: String
    /// 归属人物——所有读写都必须带这个，防止串人
    var personID: String
    var content: String
    var category: GoutouMemoryCategory
    var importance: Int
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date
    var lastConfirmedAt: Date
    /// `manual` = 你手工加的；`extract` = 从聊天里归纳的
    var source: String

    init(
        id: String = UUID().uuidString,
        personID: String,
        content: String,
        category: GoutouMemoryCategory = .stableFact,
        importance: Int = 3,
        confidence: Double = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastConfirmedAt: Date = Date(),
        source: String = "manual"
    ) {
        self.id = id
        self.personID = personID
        self.content = content
        self.category = category
        self.importance = importance
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConfirmedAt = lastConfirmedAt
        self.source = source
    }

    /// 手写解码：以后加字段也不会把老数据整份读不出来
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        personID = try container.decodeIfPresent(String.self, forKey: .personID) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        category = try container.decodeIfPresent(GoutouMemoryCategory.self, forKey: .category) ?? .stableFact
        importance = try container.decodeIfPresent(Int.self, forKey: .importance) ?? 3
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastConfirmedAt = try container.decodeIfPresent(Date.self, forKey: .lastConfirmedAt) ?? updatedAt
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "manual"
    }
}

/// MemoryExtractor 给出的一条候选操作。
enum GoutouMemoryOperation: String {
    case add = "ADD"
    case update = "UPDATE"
    case merge = "MERGE"
    case ignore = "IGNORE"
}

struct GoutouMemoryCandidate: Equatable {
    var operation: GoutouMemoryOperation
    /// UPDATE / MERGE 指向的记忆 id
    var targetID: String?
    var content: String
    var category: GoutouMemoryCategory
    var importance: Int
    var confidence: Double
}

/// 把 Extractor 的候选**当作一次事务**应用到某个人的记忆上。
///
/// 这里是纯函数：只算出「新的记忆数组」，不落盘——主分析失败或提取结果没解析成功时，
/// 调用方根本不会走到这里，记忆就不会被改。
enum GoutouMemoryApplier {

    /// 判定「说的是同一件事」的相似度阈值（去空白标点后的字符 bigram Dice + 包含关系）
    static let duplicateThreshold = 0.72
    /// 一次分析最多改动几条，防止模型抽风一次灌一堆
    static let maxChangesPerRun = 8

    static func apply(
        _ candidates: [GoutouMemoryCandidate],
        to existing: [GoutouMemoryItem],
        personID: String,
        now: Date = Date(),
        source: String = "extract"
    ) -> (items: [GoutouMemoryItem], changed: Int) {
        // 原样保留全部（AI 不能删）；只是只肯改属于这个人的那些
        var items = existing
        var changed = 0

        for candidate in candidates {
            guard changed < maxChangesPerRun else { break }
            let content = candidate.content.trimmed
            guard !content.isEmpty else { continue }

            switch candidate.operation {
            case .ignore:
                // 只是又确认了一次：内容不动，只盖个时间戳（不算「更新」）
                if let target = candidate.targetID, let index = indexOf(target, in: items, personID: personID) {
                    items[index].lastConfirmedAt = now
                }

            case .update, .merge:
                // 目标必须存在、且属于这个人；否则这条直接丢掉
                guard let target = candidate.targetID,
                      let index = indexOf(target, in: items, personID: personID) else { continue }
                let before = items[index]
                items[index].content = content
                items[index].category = candidate.category
                items[index].importance = clampImportance(candidate.importance)
                items[index].confidence = clampConfidence(candidate.confidence)
                items[index].updatedAt = now
                items[index].lastConfirmedAt = now
                items[index].source = source
                // 只有真的变了才算「更新」（单纯再确认一次不计数，免得提示虚高）
                if items[index].content != before.content
                    || items[index].category != before.category
                    || items[index].importance != before.importance {
                    changed += 1
                }

            case .add:
                // 本地再兜一道：和已有记忆高度相似就不新增，改成更新那一条
                if let index = mostSimilarIndex(to: content, in: items, personID: personID) {
                    let merged = content.count > items[index].content.count ? content : items[index].content
                    if merged != items[index].content {
                        items[index].content = merged
                        changed += 1
                    }
                    items[index].updatedAt = now
                    items[index].lastConfirmedAt = now
                } else {
                    items.append(GoutouMemoryItem(
                        personID: personID,
                        content: content,
                        category: candidate.category,
                        importance: clampImportance(candidate.importance),
                        confidence: clampConfidence(candidate.confidence),
                        createdAt: now,
                        updatedAt: now,
                        lastConfirmedAt: now,
                        source: source
                    ))
                    changed += 1
                }
            }
        }
        return (items, changed)
    }

    static func indexOf(_ id: String, in items: [GoutouMemoryItem], personID: String) -> Int? {
        items.firstIndex { $0.id == id && $0.personID == personID }
    }

    /// 找和 `content` 高度相似的那条（没有就返回 nil）
    static func mostSimilarIndex(to content: String, in items: [GoutouMemoryItem], personID: String) -> Int? {
        var best: (index: Int, score: Double)?
        for (index, item) in items.enumerated() {
            guard item.personID == personID else { continue }
            let score = similarity(content, item.content)
            if score >= duplicateThreshold, score > (best?.score ?? 0) {
                best = (index, score)
            }
        }
        return best?.index
    }

    /// 去空白/标点后的相似度：完全相同=1，包含=0.9，否则用字符 bigram Dice
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(normalized(lhs))
        let right = Array(normalized(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        let leftText = String(left)
        let rightText = String(right)
        if leftText.contains(rightText) || rightText.contains(leftText) { return 0.9 }

        let leftBigrams = bigrams(of: left)
        let rightBigrams = bigrams(of: right)
        guard !leftBigrams.isEmpty, !rightBigrams.isEmpty else { return 0 }
        let shared = leftBigrams.intersection(rightBigrams).count
        let total = leftBigrams.count + rightBigrams.count
        return total == 0 ? 0 : (2 * Double(shared)) / Double(total)
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { character in
            !character.isWhitespace && !character.isPunctuation && !character.isNewline
        }
    }

    private static func bigrams(of characters: [Character]) -> Set<String> {
        guard characters.count >= 2 else { return Set(characters.map(String.init)) }
        var result = Set<String>()
        for index in 0..<(characters.count - 1) {
            result.insert(String(characters[index...index + 1]))
        }
        return result
    }

    static func clampImportance(_ value: Int) -> Int {
        min(5, max(1, value))
    }

    static func clampConfidence(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}
