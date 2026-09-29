import Foundation

/// 记忆管理页的筛选。stale / archived 一律复用 6.7 / 6.8 的既有判断，不另算一套。
enum MemoryListFilter: String, CaseIterable {
    case all
    case recent
    case stale
    case archived

    var label: String {
        switch self {
        case .all: return "全部"
        case .recent: return "近期"
        case .stale: return "可能过期"
        case .archived: return "已归档"
        }
    }
}

/// 列表里的一行（视图只负责画，不自己判断状态）
struct MemoryListItem: Equatable {
    let id: UUID
    let content: String
    /// 「近期状态 · 45 天前 · 重要度 4/5」
    let subtitle: String
    /// 「可能过期」/「重要」/「已归档」
    let badges: [String]
    let isStale: Bool
    let archived: Bool
}

/// 详情页的一行字段
struct MemoryDetailField: Equatable {
    let name: String
    let value: String
}

/// 详情页要显示的全部内容
struct MemoryDetailModel: Equatable {
    let id: UUID
    let content: String
    let category: MemoryCategory
    let importance: Int
    let isStale: Bool
    let archived: Bool
    /// 「可能过期」/「重要」/「已归档」
    let badges: [String]
    let fields: [MemoryDetailField]
}

/// 编辑中的草稿（内容 / 分类 / 重要度可以改，id、personID、createdAt 一律不动）
struct MemoryEditDraft: Equatable {
    var content: String
    var category: MemoryCategory
    var importance: Int

    init(memory: PersonMemory) {
        content = memory.content
        category = memory.category
        importance = memory.importance
    }

    /// 点一下换下一个分类（键盘里没法弹选择器，就循环）
    mutating func nextCategory() {
        let all = MemoryCategory.allCases
        let index = all.firstIndex(of: category) ?? 0
        category = all[(index + 1) % all.count]
    }

    /// 点一下 +1（1…5 循环）
    mutating func nextImportance() {
        importance = importance >= 5 ? 1 : importance + 1
    }
}

/// 记忆管理：列表 / 搜索 / 筛选 / 详情 / 编辑草稿都是**纯计算**，
/// 只有 `apply` 会写库，而且一律走 Repository（personID 校验在那一层）。
enum MemoryManagement {

    // MARK: - 读

    /// 这个人、这个筛选、这个搜索词下的记忆列表（新→旧）
    static func items(
        personID: UUID,
        memories: [PersonMemory],
        filter: MemoryListFilter = .all,
        query: String = "",
        now: Date = Date(),
        decayConfig: MemoryDecayConfig = .default
    ) -> [MemoryListItem] {
        memories
            .filter { $0.personID == personID && !$0.content.trimmed.isEmpty }
            .filter { accepts($0, filter: filter, now: now, decayConfig: decayConfig) }
            .filter { matches($0, query: query) }
            .sorted { lhs, rhs in
                let left = MemoryDecay.effectiveDate(of: lhs)
                let right = MemoryDecay.effectiveDate(of: rhs)
                return left == right ? lhs.id.uuidString < rhs.id.uuidString : left > right
            }
            .map { makeItem($0, now: now, decayConfig: decayConfig) }
    }

    /// 某个筛选收不收这条记忆
    static func accepts(
        _ memory: PersonMemory,
        filter: MemoryListFilter,
        now: Date = Date(),
        decayConfig: MemoryDecayConfig = .default
    ) -> Bool {
        switch filter {
        case .all:
            return !memory.archived
        case .recent:
            return !memory.archived && memory.category == .recentStatus
        case .stale:
            return !memory.archived && MemoryDecay.isStale(memory, at: now, config: decayConfig)
        case .archived:
            return memory.archived
        }
    }

    /// 本地纯文本搜索（忽略大小写和空白；不做 Embedding、不联网）
    static func matches(_ memory: PersonMemory, query: String) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return true }
        return normalized(memory.content).contains(needle)
    }

    /// 每个筛选各有多少条（给筛选条上的数字用）
    static func counts(
        personID: UUID,
        memories: [PersonMemory],
        now: Date = Date(),
        decayConfig: MemoryDecayConfig = .default
    ) -> [MemoryListFilter: Int] {
        let mine = memories.filter { $0.personID == personID && !$0.content.trimmed.isEmpty }
        var result: [MemoryListFilter: Int] = [:]
        for filter in MemoryListFilter.allCases {
            result[filter] = mine.filter { accepts($0, filter: filter, now: now, decayConfig: decayConfig) }.count
        }
        return result
    }

    static func makeItem(
        _ memory: PersonMemory,
        now: Date = Date(),
        decayConfig: MemoryDecayConfig = .default
    ) -> MemoryListItem {
        let state = MemoryDecay.state(for: memory, at: now, config: decayConfig)

        let subtitle = "\(categoryTitle(memory.category)) · \(ageText(days: state.ageDays)) · 重要度 \(memory.importance)/5"
        return MemoryListItem(
            id: memory.id,
            content: memory.content,
            subtitle: subtitle,
            badges: badges(for: memory, isStale: state.isStale),
            isStale: state.isStale,
            archived: memory.archived
        )
    }

    /// 徽标：可能过期 / 重要 / 已归档（列表和详情共用同一套判断）
    static func badges(for memory: PersonMemory, isStale: Bool) -> [String] {
        var result: [String] = []
        if isStale { result.append("可能过期") }
        if memory.importance >= 4 { result.append("重要") }
        if memory.archived { result.append("已归档") }
        return result
    }

    /// 详情页（只给用户看得懂的字段，不塞内部调试信息）
    static func detail(
        id: UUID,
        personID: UUID,
        memories: [PersonMemory],
        now: Date = Date(),
        decayConfig: MemoryDecayConfig = .default
    ) -> MemoryDetailModel? {
        guard let memory = memories.first(where: { $0.id == id && $0.personID == personID }) else { return nil }
        let state = MemoryDecay.state(for: memory, at: now, config: decayConfig)

        var fields: [MemoryDetailField] = []
        fields.append(MemoryDetailField(name: "内容", value: memory.content))
        fields.append(MemoryDetailField(name: "分类", value: categoryTitle(memory.category)))
        fields.append(MemoryDetailField(name: "重要度", value: "\(memory.importance)/5"))
        fields.append(MemoryDetailField(name: "置信度", value: formatted(memory.confidence)))
        fields.append(MemoryDetailField(name: "创建时间", value: timestamp(memory.createdAt)))
        fields.append(MemoryDetailField(name: "更新时间", value: timestamp(memory.updatedAt)))
        fields.append(MemoryDetailField(
            name: "最近确认",
            value: memory.lastConfirmedAt.map(timestamp) ?? "从未"
        ))
        fields.append(MemoryDetailField(name: "来源", value: memory.sourceType.label))
        if let start = memory.sourceMessageStart, let end = memory.sourceMessageEnd {
            fields.append(MemoryDetailField(name: "来源段落", value: "第 \(start)–\(end) 段聊天"))
        }
        fields.append(MemoryDetailField(
            name: "状态",
            value: statusText(isStale: state.isStale, archived: memory.archived)
        ))

        return MemoryDetailModel(
            id: memory.id,
            content: memory.content,
            category: memory.category,
            importance: memory.importance,
            isStale: state.isStale,
            archived: memory.archived,
            badges: badges(for: memory, isStale: state.isStale),
            fields: fields
        )
    }

    /// 快捷搜索词：至少出现在两条记忆里的词（键盘里没法打字，点一下就等于输入）
    static func quickKeywords(
        personID: UUID,
        memories: [PersonMemory],
        limit: Int = 6
    ) -> [String] {
        var counts: [String: Int] = [:]
        for memory in memories where memory.personID == personID && !memory.archived {
            for keyword in Set(MemorySelector.extractKeywords(from: memory.content)) {
                counts[keyword, default: 0] += 1
            }
        }
        return counts
            .filter { $0.value >= 2 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(max(0, limit))
            .map { $0.key }
    }

    // MARK: - 写（一律走 Repository：personID 校验在那一层）

    enum Action: Equatable {
        case archive(UUID)
        case unarchive(UUID)
        /// 复用现有 confirmMemory：更新 lastConfirmedAt，stale 和权重自然恢复
        case confirm(UUID)
        /// content 传 nil 表示不改内容（内容要改时由控制器从剪贴板取）
        case update(id: UUID, content: String?, category: MemoryCategory, importance: Int)
        /// 物理删除。**只给用户手动用**：自动整理永远不删（6.8 只归档）；
        /// 界面那边必须二次确认，因为它不可恢复。
        case delete(UUID)
    }

    @discardableResult
    static func apply(
        _ action: Action,
        personID: UUID,
        from defaults: UserDefaults = .standard
    ) throws -> PersonMemory? {
        switch action {
        case .delete(let id):
            // 直接交给 Repository：它会校验归属（不是这个人的就抛 personMismatch，
            // 找不到就抛 memoryNotFound），绝不跨人物删
            try GoutouMemoryRepository.deleteMemory(id: id, personID: personID, from: defaults)
            return nil

        case .archive(let id):
            try GoutouMemoryRepository.archiveMemory(id: id, personID: personID, archived: true, from: defaults)
            return GoutouMemoryRepository.getMemory(id: id, personID: personID, from: defaults)

        case .unarchive(let id):
            try GoutouMemoryRepository.archiveMemory(id: id, personID: personID, archived: false, from: defaults)
            return GoutouMemoryRepository.getMemory(id: id, personID: personID, from: defaults)

        case .confirm(let id):
            return try GoutouMemoryRepository.confirmMemory(id: id, personID: personID, from: defaults)

        case .update(let id, let content, let category, let importance):
            let trimmed = content?.trimmed
            if let trimmed = trimmed, trimmed.isEmpty { throw MemoryRepositoryError.emptyContent }
            return try GoutouMemoryRepository.updateMemory(id: id, personID: personID, from: defaults) { memory in
                if let trimmed = trimmed { memory.content = trimmed }
                memory.category = category
                memory.importance = GoutouMemoryApplier.clampImportance(importance)
            }
        }
    }

    // MARK: - 文案

    static func categoryTitle(_ category: MemoryCategory) -> String {
        switch category {
        case .stableFact: return "长期事实"
        case .preference: return "偏好"
        case .relationship: return "关系"
        case .communicationStyle: return "沟通习惯"
        case .importantEvent: return "重要事件"
        case .recentStatus: return "近期状态"
        case .other: return "其他"
        }
    }

    static func statusText(isStale: Bool, archived: Bool) -> String {
        if archived { return "已归档（不参与分析，可随时恢复）" }
        return isStale ? "可能过期（超过阈值没再确认）" : "正常"
    }

    static func ageText(days: Double) -> String {
        let value = Int(days.rounded())
        if value <= 0 { return "今天" }
        return "\(value) 天前"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func normalized(_ text: String) -> String {
        GoutouMemoryApplier.normalized(text)
    }
}
