import Foundation

/// 连续帧稳定化：OCR 会抖（「吃饭吗」认成「吃仮吗」），所以候选必须**连续**出现在
/// N 个有效 OCR 帧里才 commit 进时间线。
///
/// 计数按「帧」算，不按「出现次数」算——同一帧里三条「哈哈」只算一帧，
/// 这样重复文本不会在第一帧就被误判成稳定。
struct LiveChatStabilizer {
    private var seen: [String: Int] = [:]

    /// 用这一帧的候选更新计数，返回「这一帧里已经稳定」的候选（保持屏幕顺序）。
    mutating func update(
        _ candidates: [LiveChatCandidate],
        config: LiveChatGeometryConfiguration = .default
    ) -> [LiveChatCandidate] {
        var updated: [String: Int] = [:]
        var stable: [LiveChatCandidate] = []
        for candidate in candidates {
            let key = candidate.fingerprint
            if updated[key] == nil {
                updated[key] = (seen[key] ?? 0) + 1
            }
            if let count = updated[key], count >= config.requiredStableObservations {
                stable.append(candidate)
            }
        }
        // 这一帧没出现的候选直接掉出计数：必须「连续」才算稳定
        seen = updated
        return stable
    }

    mutating func reset() {
        seen.removeAll()
    }

    /// 还在等下一帧确认的候选数量（只用于统计）。
    func pendingCount(required: Int) -> Int {
        seen.values.filter { $0 < required }.count
    }
}
