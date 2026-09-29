import Foundation

/// 一条记忆的「时效曲线」：多少天内算新鲜、之后怎么平滑衰减、多少天后算可能过时。
///
/// 第一版只给 `recentStatus`（近期状态）配一条。以后要给别的类别加衰减，
/// 就在 `MemoryDecayConfig.categoryCurves` 里加一行，**不要**写成散落各处的 switch。
struct MemoryDecayCurve: Equatable {
    /// ≤ freshDays：视为新鲜，系数 = 1
    var freshDays: Double
    /// freshDays 之后的衰减半衰期（天）：越大掉得越慢
    var halfLifeDays: Double
    /// 衰减下限：再久也不会归零（否则等于时间到了直接淘汰）
    var minimumMultiplier: Double
    /// 超过这个天数判定 `isStale = true`——只标记「可能过时」，**不删除、不归档**
    var staleDays: Double
}

/// 时间衰减 / stale 的**全部参数**集中在这里。
///
/// 设计要点（和 6.6 的 MemoryRankingConfig 一个思路）：数字只在这一个文件里，
/// 排序、Repository、以后的管理页都从这里读，不各写一套。
struct MemoryDecayConfig: Equatable {

    /// 近期状态：0～7 天新鲜；7 天之后平滑衰减（半衰期 45 天、下限 0.15）；60 天之后算 stale
    var recentStatusCurve = MemoryDecayCurve(
        freshDays: 7,
        halfLifeDays: 45,
        minimumMultiplier: 0.15,
        staleDays: 60
    )

    /// 以后要给别的类别加衰减就写这里（例如 preference 半年后轻微降权）。
    /// 表里没有、也不是 recentStatus 的类别 → 永不衰减（长期稳定信息不受「最近没提」影响）。
    var categoryCurves: [MemoryCategory: MemoryDecayCurve] = [:]

    /// 这个类别参不参与时间衰减
    func curve(for category: MemoryCategory) -> MemoryDecayCurve? {
        if let custom = categoryCurves[category] { return custom }
        return category == .recentStatus ? recentStatusCurve : nil
    }

    /// 哪些类别会参与衰减（给调试 / 测试看的）
    var decayingCategories: Set<MemoryCategory> {
        var result = Set(categoryCurves.keys)
        result.insert(.recentStatus)
        return result
    }

    static let `default` = MemoryDecayConfig()
}

/// 一条记忆**当前**的时效状态。全部是算出来的，不落库、不联网。
struct MemoryDecayState: Equatable {
    /// 算年龄用的时间点（lastConfirmedAt → updatedAt → createdAt）
    let effectiveDate: Date
    let ageDays: Double
    /// 排序用的时间衰减系数（1 = 完全新鲜）
    let multiplier: Double
    /// 可能过时。只是标记——不归档、不删除，再次确认就能恢复
    let isStale: Bool
}

/// 时间衰减 / stale 的**唯一计算入口**。
///
/// 三条规矩：
/// 1. 时间基准只有一个函数（`effectiveDate`），别的地方不许再自己写 `??`；
/// 2. `stale != archived != deleted`——这里只读，绝不改数据；
/// 3. 不改 `confidence` / `importance`：原始值永远保持 AI 当初的判断，
///    时间衰减只影响**当前检索权重**。
enum MemoryDecay {

    /// **统一的时间基准**：优先 lastConfirmedAt，其次 updatedAt，最后 createdAt。
    ///
    /// `updatedAt` 在解码老数据时已经会回落到 `createdAt`，这里再兜一次是为了
    /// 明确「三个时间点」的优先顺序，避免别的模块各写一套。
    static func effectiveDate(of memory: PersonMemory) -> Date {
        if let confirmed = memory.lastConfirmedAt { return confirmed }
        if memory.updatedAt != .distantPast { return memory.updatedAt }
        return memory.createdAt
    }

    static func ageDays(of memory: PersonMemory, at now: Date = Date()) -> Double {
        max(0, now.timeIntervalSince(effectiveDate(of: memory)) / 86_400)
    }

    /// 这条记忆现在的时间状态
    static func state(
        for memory: PersonMemory,
        at now: Date = Date(),
        config: MemoryDecayConfig = .default
    ) -> MemoryDecayState {
        let date = effectiveDate(of: memory)
        let age = max(0, now.timeIntervalSince(date) / 86_400)

        guard let curve = config.curve(for: memory.category) else {
            // 长期稳定信息（事实 / 偏好 / 关系 / 沟通 / 重要事件）：不随时间掉权重，也不会 stale
            return MemoryDecayState(effectiveDate: date, ageDays: age, multiplier: 1, isStale: false)
        }

        let multiplier: Double
        if age <= curve.freshDays {
            multiplier = 1
        } else {
            let decay = exp(-(age - curve.freshDays) / max(1, curve.halfLifeDays))
            multiplier = curve.minimumMultiplier + (1 - curve.minimumMultiplier) * decay
        }
        return MemoryDecayState(
            effectiveDate: date,
            ageDays: age,
            multiplier: multiplier,
            isStale: age > curve.staleDays
        )
    }

    /// 排序权重系数（平滑，不做阶梯归零）
    static func multiplier(
        for memory: PersonMemory,
        at now: Date = Date(),
        config: MemoryDecayConfig = .default
    ) -> Double {
        state(for: memory, at: now, config: config).multiplier
    }

    /// 可能过时（recentStatus 超过 staleDays 且之后没再确认过）
    static func isStale(
        _ memory: PersonMemory,
        at now: Date = Date(),
        config: MemoryDecayConfig = .default
    ) -> Bool {
        state(for: memory, at: now, config: config).isStale
    }
}

/// 方便读的语法糖：`memory.isStale(at:)` / `memory.decayMultiplier(at:)`
extension PersonMemory {
    /// 和 `MemoryDecay.effectiveDate(of:)` 同一个口径
    var effectiveMemoryDate: Date { MemoryDecay.effectiveDate(of: self) }

    func decayMultiplier(at now: Date = Date(), config: MemoryDecayConfig = .default) -> Double {
        MemoryDecay.multiplier(for: self, at: now, config: config)
    }

    func isStale(at now: Date = Date(), config: MemoryDecayConfig = .default) -> Bool {
        MemoryDecay.isStale(self, at: now, config: config)
    }
}
