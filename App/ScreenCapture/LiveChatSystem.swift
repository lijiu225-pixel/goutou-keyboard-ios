import Foundation

/// 给界面看的快照：值类型，可以安全跨线程交给 MainActor。
struct LiveChatSnapshot: Equatable {
    var messages: [LiveChatCandidate] = []
    /// 当前屏幕识别出的候选条数
    var candidatesThisFrame = 0
    /// 这一帧里已经稳定的候选条数
    var stableThisFrame = 0
    /// 还在等下一帧确认的候选条数
    var pendingCandidates = 0
    /// 时间线里未确定角色的条数
    var unknownCount = 0
    /// 因为重复而丢掉的条数
    var duplicateDrops = 0
    /// 因为超过上限而丢掉的旧条数
    var truncatedOldest = 0
    /// 已经到上限时被拒绝的更旧条目数
    var droppedAtCap = 0
    /// 连续多帧找不到可靠 overlap 的次数
    var discontinuityFrames = 0
    /// 最近一次合并是否发现「不连续聊天区域」
    var showsDiscontinuity = false
    var generation = 0

    static let empty = LiveChatSnapshot()
}

/// 阶段 12B 的聊天识别流水线（纯值类型、不联网、不落盘、不碰键盘）：
///
/// observations → 聊天区域过滤 → 多行合并成块 → 保守角色判断 → 连续帧稳定化 → 时间线合并。
///
/// 调用方负责在**后台串行队列**上调用 `ingest`（分组、编辑距离、overlap 都是重活），
/// UI 只读它返回的快照。
struct LiveChatSystem {
    private var timeline = LiveChatTimeline()
    private var stabilizer = LiveChatStabilizer()
    private var config = LiveChatGeometryConfiguration.default
    private var generation = 0
    private var candidatesThisFrame = 0
    private var stableThisFrame = 0

    /// 新 session / 用户点「清空实时聊天」：只清阶段 12B 的状态，不动屏幕捕获。
    mutating func reset(generation: Int) {
        timeline.reset()
        stabilizer.reset()
        self.generation = generation
        candidatesThisFrame = 0
        stableThisFrame = 0
    }

    /// 吃一帧 OCR 结果，返回最新快照。
    mutating func ingest(
        observations: [LiveOCRObservation],
        timestamp: Date,
        generation: Int,
        config: LiveChatGeometryConfiguration = .default
    ) -> LiveChatSnapshot {
        // 旧代际的迟到帧：一个字都不写（新 session 由调用方显式 reset 开好头）
        guard generation == self.generation else { return snapshot() }
        self.config = config

        let inViewport = LiveChatViewportFilter.filter(observations, config: config)
        let candidates = LiveChatBlockGrouper.group(inViewport, config: config, timestamp: timestamp)
        return ingest(candidates: candidates, timestamp: timestamp, generation: generation, config: config)
    }

    /// 已经把候选块算好时走这里（阶段 12E 的门控要先算一遍候选来判断「像不像聊天界面」，
    /// 算好的结果直接复用，不重复分组）。
    mutating func ingest(
        candidates: [LiveChatCandidate],
        timestamp: Date,
        generation: Int,
        config: LiveChatGeometryConfiguration = .default
    ) -> LiveChatSnapshot {
        guard generation == self.generation else { return snapshot() }
        self.config = config
        candidatesThisFrame = candidates.count

        let stable = stabilizer.update(candidates, config: config)
        stableThisFrame = stable.count

        timeline.merge(stable, config: config)
        return snapshot()
    }

    func snapshot() -> LiveChatSnapshot {
        LiveChatSnapshot(
            messages: timeline.messages,
            candidatesThisFrame: candidatesThisFrame,
            stableThisFrame: stableThisFrame,
            pendingCandidates: stabilizer.pendingCount(required: config.requiredStableObservations),
            unknownCount: timeline.messages.filter { $0.role == .unknown }.count,
            duplicateDrops: timeline.duplicateDrops,
            truncatedOldest: timeline.truncatedOldest,
            droppedAtCap: timeline.droppedAtCap,
            discontinuityFrames: timeline.discontinuityFrames,
            showsDiscontinuity: timeline.lastDiscontinuity,
            generation: generation
        )
    }
}
