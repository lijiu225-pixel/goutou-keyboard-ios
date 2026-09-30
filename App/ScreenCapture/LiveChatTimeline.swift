import CoreGraphics
import Foundation

/// 实时聊天时间线：**只放内存**。
///
/// 不写共享聊天文件、不落盘、不写偏好设置、不碰人物记忆；
/// 上限 200 条（与剪贴板契约一致），超出丢最早的。
struct LiveChatTimeline: Equatable {
    private(set) var messages: [LiveChatCandidate] = []
    /// 因为「已经在时间线里」而丢掉的重复条数
    private(set) var duplicateDrops = 0
    /// 因为超过上限而丢掉的旧条数
    private(set) var truncatedOldest = 0
    /// 已经到上限时被拒绝的更旧条目数（它们从没进过时间线）
    private(set) var droppedAtCap = 0
    /// 连续多帧都找不到可靠 overlap 的次数
    private(set) var discontinuityFrames = 0
    /// 最近一次合并是否发现「不连续聊天区域」
    private(set) var lastDiscontinuity = false

    mutating func reset() {
        messages.removeAll()
        duplicateDrops = 0
        truncatedOldest = 0
        droppedAtCap = 0
        discontinuityFrames = 0
        lastDiscontinuity = false
    }

    /// 把「当前屏幕的稳定消息序列」并进时间线。
    ///
    /// 靠**连续序列**找最大可靠 overlap（单条文本不可靠，尤其「哈哈」这种重复消息），
    /// 找不到就只记一次「不连续」，绝不硬拼。
    mutating func merge(
        _ visible: [LiveChatCandidate],
        config: LiveChatGeometryConfiguration = .default
    ) {
        lastDiscontinuity = false
        guard !visible.isEmpty else { return }

        guard !messages.isEmpty else {
            messages = visible
            enforceCap(config: config)
            return
        }

        guard let match = Self.bestOverlap(visible: visible, timeline: messages, config: config) else {
            discontinuityFrames += 1
            lastDiscontinuity = true
            return
        }

        let anchorStart = match.timelineIndex
        let anchorEnd = match.timelineIndex + match.length
        let visibleEnd = match.visibleIndex + match.length

        // 比 anchor 新的那些：只有 anchor 正好在时间线末尾时才往后接
        if anchorEnd == messages.count {
            for item in visible[visibleEnd...] {
                if let last = messages.last, Self.sameMessage(item, last, config: config) {
                    duplicateDrops += 1
                    continue
                }
                messages.append(item)
            }
        } else if !visible[visibleEnd...].allSatisfy({ item in
            messages.contains { Self.sameMessage(item, $0, config: config) }
        }) {
            // anchor 不在末尾，而屏幕后面出现了时间线里没有的内容：保守起见不插到中间
            lastDiscontinuity = true
        }

        // 比 anchor 旧的那些：只有 anchor 正好在时间线开头时才往前插
        if anchorStart == 0 {
            let prefix = visible[0..<match.visibleIndex]
            if messages.count >= config.maxTimelineMessages {
                // 已经到上限：插进来也会被立刻丢掉，干脆不收，免得反复插了又删
                droppedAtCap += prefix.count
            } else {
                let fresh = prefix.filter { item in
                    !messages.contains { Self.sameMessage(item, $0, config: config) }
                }
                duplicateDrops += prefix.count - fresh.count
                if !fresh.isEmpty { messages.insert(contentsOf: fresh, at: 0) }
            }
        } else if !visible[0..<match.visibleIndex].allSatisfy({ item in
            messages.contains { Self.sameMessage(item, $0, config: config) }
        }) {
            lastDiscontinuity = true
        }

        enforceCap(config: config)
    }

    private mutating func enforceCap(config: LiveChatGeometryConfiguration) {
        guard messages.count > config.maxTimelineMessages else { return }
        let overflow = messages.count - config.maxTimelineMessages
        messages.removeFirst(overflow)
        truncatedOldest += overflow
    }

    // MARK: - 匹配

    /// 两条候选算不算同一条消息：role 必须一样，文本归一化后相同或足够相似。
    static func sameMessage(
        _ lhs: LiveChatCandidate,
        _ rhs: LiveChatCandidate,
        config: LiveChatGeometryConfiguration = .default
    ) -> Bool {
        guard lhs.role == rhs.role else { return false }
        if lhs.normalizedText == rhs.normalizedText { return true }
        guard !lhs.normalizedText.isEmpty, !rhs.normalizedText.isEmpty else { return false }
        return LiveChatText.similarity(lhs.normalizedText, rhs.normalizedText) >= config.similarityThreshold
    }

    /// 最长连续匹配：单条不可靠，连续 2～3 条上下文才算数。
    struct OverlapMatch: Equatable {
        let timelineIndex: Int
        let visibleIndex: Int
        let length: Int
    }

    static func bestOverlap(
        visible: [LiveChatCandidate],
        timeline: [LiveChatCandidate],
        config: LiveChatGeometryConfiguration = .default
    ) -> OverlapMatch? {
        guard !visible.isEmpty, !timeline.isEmpty else { return nil }
        let timelineStart = max(0, timeline.count - config.overlapSearchWindow)
        let visibleLimit = min(visible.count, config.overlapSearchWindow)
        // 屏幕上一共只看到一两条时，允许单条 overlap；否则至少要连续两条才算可靠。
        let requiredLength = min(config.minimumOverlapLength, visible.count, timeline.count)
        var best: OverlapMatch?

        for i in timelineStart..<timeline.count {
            for j in 0..<visibleLimit {
                var length = 0
                while i + length < timeline.count,
                      j + length < visible.count,
                      sameMessage(visible[j + length], timeline[i + length], config: config) {
                    length += 1
                }
                guard length >= requiredLength else { continue }
                if best == nil || length > best!.length {
                    best = OverlapMatch(timelineIndex: i, visibleIndex: j, length: length)
                }
            }
        }
        return best
    }
}
