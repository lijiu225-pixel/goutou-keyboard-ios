import Foundation

/// 灵动岛 / 锁屏 Live Activity 要展示的内容：**只有状态与计数，绝不含聊天正文**。
struct GoutouCaptureActivityContent: Equatable {
    var capturing: Bool
    var gateText: String
    var autoSyncText: String
    var timelineCount: Int
    var syncedCount: Int
    var unknownCount: Int
    var lastSyncAt: Date?
    var errorText: String?

    /// 自检用的人类可读描述（测试拿它证明「没有正文」）。
    var summary: String {
        var parts = ["capturing=\(capturing)", "gate=\(gateText)", "autoSync=\(autoSyncText)",
                     "timeline=\(timelineCount)", "synced=\(syncedCount)", "unknown=\(unknownCount)"]
        if let lastSyncAt { parts.append("lastSync=\(lastSyncAt.timeIntervalSince1970)") }
        if let errorText { parts.append("error=\(errorText)") }
        return parts.joined(separator: " ")
    }
}

/// 从 App 的各个状态映射出 Live Activity 内容（纯函数，可测）。
enum GoutouCaptureActivityContentBuilder {
    static func make(
        captureState: LiveScreenCaptureState,
        verdict: ChatSceneVerdict,
        autoSync: LiveChatAutoSyncState,
        timelineCount: Int,
        unknownCount: Int,
        syncedCount: Int,
        lastSyncAt: Date?
    ) -> GoutouCaptureActivityContent {
        var errorText: String?
        if case .failed(let reason) = captureState { errorText = reason }
        if case .failed(let reason) = autoSync { errorText = reason }

        return GoutouCaptureActivityContent(
            capturing: captureState.isCapturing,
            gateText: verdict.shortTitle,
            autoSyncText: autoSync.title,
            timelineCount: timelineCount,
            syncedCount: syncedCount,
            unknownCount: unknownCount,
            lastSyncAt: lastSyncAt,
            errorText: errorText
        )
    }
}

/// 规划器要执行的动作。
enum GoutouCaptureActivityAction: Equatable {
    case none
    case start(GoutouCaptureActivityContent)
    case update(GoutouCaptureActivityContent)
    case end(GoutouCaptureActivityContent)
}

/// 纯决策：什么时候创建 / 更新 / 结束 Live Activity，以及节流与去重。
///
/// 规则：只有真正开始捕获才创建；相同内容不重复 update；两次 update 之间至少隔
/// `minimumUpdateInterval`（避免每帧都推灵动岛）；停止 / 失败时结束。
struct GoutouCaptureActivityPlanner {
    /// 两次 update 的最小间隔
    var minimumUpdateInterval: TimeInterval = 1.0

    private(set) var lastPushed: GoutouCaptureActivityContent?
    private(set) var lastPushAt: Date?
    private(set) var isRunning = false
    private(set) var sessionID: String?
    /// 被节流 / 去重挡掉的次数（只用于统计）
    private(set) var skippedUpdates = 0

    mutating func captureStarted(
        sessionID: String,
        content: GoutouCaptureActivityContent,
        now: Date = Date()
    ) -> GoutouCaptureActivityAction {
        self.sessionID = sessionID
        isRunning = true
        lastPushed = content
        lastPushAt = now
        return .start(content)
    }

    mutating func stateChanged(
        _ content: GoutouCaptureActivityContent,
        now: Date = Date()
    ) -> GoutouCaptureActivityAction {
        // 没在跑就不创建 Activity（避免「假灵动岛」）
        guard isRunning else {
            skippedUpdates += 1
            return .none
        }
        // 相同状态不重复 update
        guard content != lastPushed else {
            skippedUpdates += 1
            return .none
        }
        // 节流：短时间内连续变化只保留最后一次会推的
        if let lastPushAt, now.timeIntervalSince(lastPushAt) < minimumUpdateInterval {
            skippedUpdates += 1
            return .none
        }
        lastPushed = content
        lastPushAt = now
        return .update(content)
    }

    mutating func captureStopped(
        _ content: GoutouCaptureActivityContent,
        now: Date = Date()
    ) -> GoutouCaptureActivityAction {
        guard isRunning else { return .none }
        isRunning = false
        lastPushed = content
        lastPushAt = now
        sessionID = nil
        return .end(content)
    }
}
