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
    var recognitionHoldReason: String? = nil

    var statusText: String {
        guard capturing else { return "已停止" }
        if gateText == ChatSceneVerdict.inactive.shortTitle { return "未在聊天界面 · 已暂停识别" }
        if let recognitionHoldReason { return recognitionHoldReason }
        if unknownCount > 0 { return "\(unknownCount) 条未确定 · 同步暂停" }
        if gateText == ChatSceneVerdict.activeChat.shortTitle { return "已进入聊天 · 识别中" }
        return gateText
    }

    /// 紧凑态右侧：**正常识别时优先显示实时聊天条数**（🐾 8条），不用长按灵动岛。
    ///
    /// - 正在识别：`N条`
    /// - 有未确定：`N·!M`（实时 N 条，其中 M 条未确定）
    /// - 不在聊天界面：`暂停`
    /// - 捕获停止：`停止`（随后按既有生命周期结束 Activity）
    var compactText: String {
        guard capturing else { return "停止" }
        guard gateText == ChatSceneVerdict.activeChat.shortTitle else { return "暂停" }
        if recognitionHoldReason != nil { return "确认" }
        if unknownCount > 0 { return "\(min(timelineCount, 999))·!\(min(unknownCount, 99))" }
        return "\(min(timelineCount, 999))条"
    }

    /// minimal 比 compact 更窄：只给数字或很短的符号，宁可少写字也不要被系统截断。
    var minimalText: String {
        guard capturing else { return "停" }
        guard gateText == ChatSceneVerdict.activeChat.shortTitle else { return "Ⅱ" }
        if recognitionHoldReason != nil { return "?" }
        if unknownCount > 0 { return "!\(min(unknownCount, 9))" }
        return "\(min(timelineCount, 99))"
    }

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
        lastSyncAt: Date?,
        recognitionHoldReason: String? = nil
    ) -> GoutouCaptureActivityContent {
        var errorText: String?
        if case .failed = captureState { errorText = "屏幕捕获失败" }
        if case .failed = autoSync { errorText = "自动同步失败" }
        let syncText: String
        switch autoSync {
        case .failed: syncText = "自动同步失败"
        case .disabled: syncText = "自动同步未开启"
        default: syncText = autoSync.title
        }

        return GoutouCaptureActivityContent(
            capturing: captureState.isCapturing,
            gateText: verdict.shortTitle,
            autoSyncText: syncText,
            timelineCount: timelineCount,
            syncedCount: syncedCount,
            unknownCount: unknownCount,
            lastSyncAt: lastSyncAt,
            errorText: errorText,
            recognitionHoldReason: recognitionHoldReason
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
    private(set) var pending: GoutouCaptureActivityContent?
    var pendingDeadline: Date? {
        guard pending != nil, let lastPushAt else { return nil }
        return lastPushAt.addingTimeInterval(minimumUpdateInterval)
    }

    mutating func captureStarted(
        sessionID: String,
        content: GoutouCaptureActivityContent,
        now: Date = Date()
    ) -> GoutouCaptureActivityAction {
        guard content.capturing else { return .none }
        if isRunning && self.sessionID == sessionID { return stateChanged(content, now: now) }
        self.sessionID = sessionID
        pending = nil
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
            pending = nil
            skippedUpdates += 1
            return .none
        }
        // 节流：短时间内连续变化只保留最后一次会推的
        if let lastPushAt, now.timeIntervalSince(lastPushAt) < minimumUpdateInterval {
            pending = content
            skippedUpdates += 1
            return .none
        }
        lastPushed = content
        lastPushAt = now
        pending = nil
        return .update(content)
    }

    mutating func flush(now: Date = Date()) -> GoutouCaptureActivityAction {
        guard let pending else { return .none }
        return stateChanged(pending, now: now)
    }

    mutating func captureStopped(
        _ content: GoutouCaptureActivityContent,
        now: Date = Date()
    ) -> GoutouCaptureActivityAction {
        guard isRunning else { return .none }
        isRunning = false
        pending = nil
        lastPushed = content
        lastPushAt = now
        sessionID = nil
        return .end(content)
    }
}
