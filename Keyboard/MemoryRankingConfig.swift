import Foundation

/// 当前任务类型。面板以后会有任务选择器，现在写死用「分析意思」，
/// 但排序规则已经按任务类型分开配好了，接线时只改传进来的值。
enum MemoryTaskType: String, CaseIterable {
    case analyzeMeaning
    case analyzeRelationship
    case helpReply

    var label: String {
        switch self {
        case .analyzeMeaning: return "分析意思"
        case .analyzeRelationship: return "分析关系"
        case .helpReply: return "帮我回复"
        }
    }

    /// 和 `GoutouPrompt.task`（写死的那句）保持一致
    static let current: MemoryTaskType = .analyzeMeaning
}

/// 记忆排序的**全部权重与预算都集中在这里**，不再散落到别处。
struct MemoryRankingConfig: Equatable {

    // 评分权重
    var importanceWeight: Double = 1.6
    var confidenceWeight: Double = 1.2
    var recencyWeight: Double = 2.4
    var confirmedWeight: Double = 0.8
    var keywordWeight: Double = 4.0
    var categoryWeight: Double = 1.2

    // 预算
    var defaultTopK: Int = 20
    /// 字符预算：一条记忆可能很长，到量就停，**不截断半句话**
    var maxMemoryCharacters: Int = 3000

    // 保底与去重
    /// Top-K 里留给「长期高重要度」的比例（约 20%～30%）
    var baselineRatio: Double = 0.25
    /// 相似到这个程度就算近义，同一批 Prompt 里不重复占太多名额
    var redundancyThreshold: Double = 0.72
    /// 近义第二条的分数折扣（仍然可能作为补位进来）
    var redundancyPenalty: Double = 0.55
    /// 同一话题（同类别 + 都和本次聊天相关）最多占几个 Top-K 名额
    var maxPerTopic: Int = 3

    // 时间衰减
    /// 半衰期：越久分越低，但不会归零
    var recencyHalfLifeDays: Double = 60
    /// 再久也保底这个比例的分，不做硬截断
    var recencyFloor: Double = 0.15

    /// 类别不在优先级列表里时的分（仍然参与，不会因为没列到就出局）
    var categoryUnlistedScore: Double = 0.35
    /// 类别优先级每降一名扣多少
    var categoryStepPenalty: Double = 0.12

    /// 保底记忆的门槛：特别重要的事件/关系，或高重要度的长期事实
    var baselineMinImportance: Int = 4
    var baselineRelationMinImportance: Int = 3

    /// 每个任务优先看哪些类别（越靠前分越高）。stableFact 仍在列表里，但不再是永远第一。
    var categoryPriorities: [MemoryTaskType: [MemoryCategory]] = [
        .helpReply: [.communicationStyle, .relationship, .recentStatus, .preference, .importantEvent, .stableFact, .other],
        .analyzeRelationship: [.relationship, .importantEvent, .communicationStyle, .recentStatus, .preference, .stableFact, .other],
        .analyzeMeaning: [.recentStatus, .communicationStyle, .relationship, .preference, .importantEvent, .stableFact, .other],
    ]

    /// 时间衰减 / stale 的参数（6.7）。放在这里是为了「排序相关的可调项只有一个入口」，
    /// 具体数字仍然集中在 `MemoryDecayConfig`。
    var decay: MemoryDecayConfig = .default

    static let `default` = MemoryRankingConfig()
}
