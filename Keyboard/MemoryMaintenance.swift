import Foundation

/// 整理动作。本阶段**只有这三种，没有 DELETE**。
enum MemoryMaintenanceAction: String {
    case keep = "KEEP"
    case merge = "MERGE"
    case archive = "ARCHIVE"

    var label: String {
        switch self {
        case .keep: return "保留"
        case .merge: return "合并"
        case .archive: return "归档"
        }
    }
}

/// 整理的可调参数（和 Ranking / Decay 一样，数字只在这一个文件里）。
struct MemoryMaintenanceConfig: Equatable {
    /// 合并的相似度门槛：沿用现有去重同一套口径（去空白标点后的字符 bigram Dice）
    var mergeSimilarityThreshold: Double = 0.72
    /// 合并后内容长度上限；超过就只留更长的那条，不硬拼
    var mergedContentLimit: Int = 120
    /// importance ≥ 这个值就**不归档**（保护高重要度记忆）
    var archiveImportanceCeiling: Int = 3
    /// 只有这些类别允许被自动归档（长期稳定信息不在里面）
    var archiveCategories: Set<MemoryCategory> = [.recentStatus]
    /// 记忆条数达到这个量就整理一次
    var memoryCountTrigger: Int = 40
    /// 每 N 次成功分析整理一次
    var analysisTrigger: Int = 5
    /// 两次整理之间至少隔多久（小时），避免连续分析反复整理
    var minimumIntervalHours: Double = 6
    /// 一次整理最多动几条，防止一次动太多
    var maxChangesPerRun: Int = 12

    static let `default` = MemoryMaintenanceConfig()
}

/// 一次整理里对某条记忆做的事（只记录，不落盘）
struct MemoryMaintenanceChange: Equatable {
    let action: MemoryMaintenanceAction
    /// MERGE：合并后保留的那条；ARCHIVE：被归档的那条
    let memoryID: UUID
    /// 被并进 `memoryID` 的那几条（内容已经并入）
    let mergedIDs: [UUID]
    let reason: String
}

/// 整理计划：算出来的新数组 + 做了哪些事（纯计算结果，还没写库）
struct MemoryMaintenancePlan: Equatable {
    let personID: UUID
    let items: [PersonMemory]
    let changes: [MemoryMaintenanceChange]

    /// 合并了几组
    var mergedGroupCount: Int { changes.filter { $0.action == .merge }.count }
    /// 有多少条记忆被并掉了
    var absorbedCount: Int {
        changes.filter { $0.action == .merge }.reduce(0) { $0 + $1.mergedIDs.count }
    }
    var archivedCount: Int { changes.filter { $0.action == .archive }.count }
    var isEmpty: Bool { changes.isEmpty }
}

/// 记忆整理：**只读 + 纯计算**，算完校验通过才一次性写回（等价事务）。
///
/// 三条底线：
/// 1. 只碰 `currentPersonID` 的记忆，写回前再校验一次 personID；
/// 2. 只有 KEEP / MERGE / ARCHIVE，没有 DELETE——归档只是 `archived = true`；
/// 3. 不确定就 KEEP。整理不联网、不花 Token、没有 Timer。
enum MemoryMaintenance {

    // MARK: - 触发时机（计数 + 间隔，都在 UserDefaults 里）

    static let analysesSinceRunKey = "goutou.mentor.maintenance.analyses"
    static let lastRunAtKey = "goutou.mentor.maintenance.lastRunAt"

    /// 到点了吗？两个触发条件任一满足 + 距上次整理够久
    static func shouldRun(
        memoryCount: Int,
        analysesSinceRun: Int,
        lastRunAt: Date?,
        now: Date = Date(),
        config: MemoryMaintenanceConfig = .default
    ) -> Bool {
        let reached = memoryCount >= config.memoryCountTrigger
            || analysesSinceRun >= config.analysisTrigger
        guard reached else { return false }
        if let lastRunAt = lastRunAt,
           now.timeIntervalSince(lastRunAt) < config.minimumIntervalHours * 3_600 {
            return false
        }
        return true
    }

    /// 每次分析成功、记忆写完之后调一次。
    /// 累加计数；到点就整理一次（本地），否则什么都不做。
    @discardableResult
    static func noteAnalysisAndMaybeRun(
        personID: UUID,
        now: Date = Date(),
        decayConfig: MemoryDecayConfig = .default,
        config: MemoryMaintenanceConfig = .default,
        from defaults: UserDefaults = .standard
    ) -> MemoryMaintenancePlan? {
        let count = (defaults.object(forKey: analysesSinceRunKey) as? Int ?? 0) + 1
        defaults.set(count, forKey: analysesSinceRunKey)

        let memories = GoutouMemoryRepository.getMemories(
            personID: personID,
            includeArchived: true,
            from: defaults
        )
        let lastRunAt = defaults.object(forKey: lastRunAtKey) as? Date
        guard shouldRun(
            memoryCount: memories.count,
            analysesSinceRun: count,
            lastRunAt: lastRunAt,
            now: now,
            config: config
        ) else { return nil }

        defaults.set(0, forKey: analysesSinceRunKey)
        defaults.set(now, forKey: lastRunAtKey)
        return run(personID: personID, now: now, decayConfig: decayConfig, config: config, from: defaults)
    }

    // MARK: - 算（纯函数：不写库）

    static func plan(
        personID: UUID,
        memories: [PersonMemory],
        now: Date = Date(),
        decayConfig: MemoryDecayConfig = .default,
        config: MemoryMaintenanceConfig = .default
    ) -> MemoryMaintenancePlan {
        // 只认这个人的、有内容的；别人的记忆连碰都不碰
        var items = memories.filter { $0.personID == personID && !$0.content.trimmed.isEmpty }
        var changes: [MemoryMaintenanceChange] = []
        var budget = max(0, config.maxChangesPerRun)

        mergeInPlace(&items, changes: &changes, budget: &budget, now: now, config: config)
        archiveInPlace(&items, changes: &changes, budget: &budget, now: now, decayConfig: decayConfig, config: config)

        return MemoryMaintenancePlan(personID: personID, items: items, changes: changes)
    }

    /// 能不能合并这两条。
    /// 保守优先：类别必须一样、必须高度相似、**数字不一样就一律不并**。
    static func canMerge(
        _ lhs: PersonMemory,
        _ rhs: PersonMemory,
        config: MemoryMaintenanceConfig = .default
    ) -> Bool {
        guard lhs.id != rhs.id else { return false }
        guard lhs.personID == rhs.personID else { return false }
        guard lhs.category == rhs.category else { return false }
        guard !lhs.archived, !rhs.archived else { return false }
        // 「3 月 5 日」和「3 月 6 日」长得很像，但显然不是同一件事
        guard digitSignature(lhs.content) == digitSignature(rhs.content) else { return false }
        return GoutouMemoryApplier.similarity(lhs.content, rhs.content) >= config.mergeSimilarityThreshold
    }

    /// 内容里的数字（日期 / 金额 / 次数）——用来挡住「日期不一样却被合并」
    static func digitSignature(_ text: String) -> String {
        String(text.filter { $0.isNumber })
    }

    /// 合并：保留 `survivor` 的身份（id / personID / createdAt 不变），
    /// 内容取更完整的那份，importance / confidence / lastConfirmedAt 取两者的较大值。
    ///
    /// 注意：合并**不会**把 `updatedAt` 刷成现在——否则一条 90 天没确认的近况
    /// 会因为"并过一次"就重新显得新鲜（6.7 的衰减看的就是这个时间）。
    static func merge(
        _ survivor: PersonMemory,
        _ absorbed: PersonMemory,
        config: MemoryMaintenanceConfig = .default
    ) -> PersonMemory {
        var result = survivor
        result.content = mergedContent(survivor.content, absorbed.content, limit: config.mergedContentLimit)
        result.importance = max(survivor.importance, absorbed.importance)
        result.confidence = max(survivor.confidence, absorbed.confidence)
        result.lastConfirmedAt = latest(survivor.lastConfirmedAt, absorbed.lastConfirmedAt)
        result.updatedAt = max(survivor.updatedAt, absorbed.updatedAt)
        return result
    }

    /// 合并后的内容：包含关系就留更长的那条；否则拼起来（超长就退回更长的那条）。
    static func mergedContent(_ lhs: String, _ rhs: String, limit: Int) -> String {
        let a = lhs.trimmed
        let b = rhs.trimmed
        if a == b { return a }
        let na = GoutouMemoryApplier.normalized(a)
        let nb = GoutouMemoryApplier.normalized(b)
        if na.contains(nb) { return a }
        if nb.contains(na) { return b }
        let (longer, shorter) = a.count >= b.count ? (a, b) : (b, a)
        let joined = "\(longer)；\(shorter)"
        return joined.count <= limit ? joined : longer
    }

    // MARK: - 落盘（校验通过才写，等价事务）

    /// 安全校验：条数只可能因为合并而减少、人不能串、不能凭空出现新 id。
    /// 任何一条不满足就放弃整理——**一个字都不改**。
    static func isSafe(
        _ plan: MemoryMaintenancePlan,
        against existing: [PersonMemory],
        personID: UUID
    ) -> Bool {
        guard plan.personID == personID else { return false }
        guard plan.items.allSatisfy({ $0.personID == personID }) else { return false }
        let ids = plan.items.map { $0.id }
        guard Set(ids).count == ids.count else { return false }
        guard Set(ids).isSubset(of: Set(existing.map { $0.id })) else { return false }
        guard plan.items.count == existing.count - plan.absorbedCount else { return false }
        let existingIDs = Set(existing.map { $0.id })
        return plan.changes.allSatisfy { change in
            guard existingIDs.contains(change.memoryID) else { return false }
            return change.mergedIDs.allSatisfy { existingIDs.contains($0) }
        }
    }

    /// 整理这个人：先算，再校验，最后一次性写回。失败返回 nil（原数据不动）。
    @discardableResult
    static func run(
        personID: UUID,
        now: Date = Date(),
        decayConfig: MemoryDecayConfig = .default,
        config: MemoryMaintenanceConfig = .default,
        from defaults: UserDefaults = .standard
    ) -> MemoryMaintenancePlan? {
        let existing = GoutouMemoryRepository.getMemories(
            personID: personID,
            includeArchived: true,
            from: defaults
        )
        guard !existing.isEmpty else { return nil }

        let plan = plan(personID: personID, memories: existing, now: now, decayConfig: decayConfig, config: config)
        guard !plan.isEmpty else { return nil }
        guard isSafe(plan, against: existing, personID: personID) else { return nil }

        do {
            try GoutouMemoryRepository.replaceMemories(plan.items, personID: personID, from: defaults)
        } catch {
            // 落盘失败：原数据没被改过（replaceMemories 是整份覆盖，不会改到一半）
            return nil
        }
        return plan
    }

    // MARK: - 内部

    /// 同类别高度相似的并成一条。存活的是数组里靠前的那条（插入更早，id 更稳定）。
    private static func mergeInPlace(
        _ items: inout [PersonMemory],
        changes: inout [MemoryMaintenanceChange],
        budget: inout Int,
        now: Date,
        config: MemoryMaintenanceConfig
    ) {
        var absorbedByTarget: [UUID: [UUID]] = [:]
        var index = 0
        while index < items.count, budget > 0 {
            guard !items[index].archived else {
                index += 1
                continue
            }
            var scan = index + 1
            while scan < items.count, budget > 0 {
                guard canMerge(items[index], items[scan], config: config) else {
                    scan += 1
                    continue
                }
                let targetID = items[index].id
                let absorbedID = items[scan].id
                items[index] = merge(items[index], items[scan], config: config)
                absorbedByTarget[targetID, default: []].append(absorbedID)
                items.remove(at: scan)
                budget -= 1
            }
            index += 1
        }
        for (targetID, absorbed) in absorbedByTarget.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            changes.append(MemoryMaintenanceChange(
                action: .merge,
                memoryID: targetID,
                mergedIDs: absorbed,
                reason: "同类别 + 高度相似，并成一条更完整的记忆"
            ))
        }
    }

    /// 只归档「近期状态 + 已经 stale + 不重要」的：翻一个 `archived` 位，
    /// 时间字段和内容一个都不动（6.7 的衰减判断靠它们）。
    private static func archiveInPlace(
        _ items: inout [PersonMemory],
        changes: inout [MemoryMaintenanceChange],
        budget: inout Int,
        now: Date,
        decayConfig: MemoryDecayConfig,
        config: MemoryMaintenanceConfig
    ) {
        for index in items.indices where budget > 0 {
            let memory = items[index]
            guard !memory.archived else { continue }
            guard config.archiveCategories.contains(memory.category) else { continue }
            guard memory.importance <= config.archiveImportanceCeiling else { continue }
            guard MemoryDecay.isStale(memory, at: now, config: decayConfig) else { continue }

            let staleDays = decayConfig.curve(for: memory.category)?.staleDays ?? 0
            items[index].archived = true
            changes.append(MemoryMaintenanceChange(
                action: .archive,
                memoryID: memory.id,
                mergedIDs: [],
                reason: "近期状态超过 \(Int(staleDays)) 天没再确认，价值较低 → 归档（仍然保留，可随时取消）"
            ))
            budget -= 1
        }
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        default: return nil
        }
    }
}
