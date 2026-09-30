import Foundation

/// 自动同步要调用的「外部动作」：真正写盘由协调器执行，这里只做决定。
enum LiveChatAutoSyncEffect: Equatable {
    case idle
    /// 到某个时刻再来问一次
    case schedule(deadline: Date)
    /// 取消已经排队的检查
    case cancelScheduled
    /// 现在写这份冻结快照（调用方执行 SharedChatStore.save）
    case save(LiveChatAutoSyncSnapshot)
}

/// 排队中的一份快照 + 它的期限。
struct LiveChatAutoSyncPending: Equatable {
    var snapshot: LiveChatAutoSyncSnapshot
    var deadline: Date
}

/// 阶段 12D 的纯决策层：授权、资格判断、fingerprint、debounce、最低写入间隔、
/// 并发保护、代际隔离、人工保存防覆盖。
///
/// 不碰计时器、不碰文件、不碰 UI；时间全部由调用方传入，所以测试可以随便推进时间，
/// 不用真的等 1.5 秒。
struct LiveChatAutoSyncSession {
    private(set) var state: LiveChatAutoSyncState = .disabled
    private(set) var enabled = false
    private(set) var generation = 0
    private(set) var pending: LiveChatAutoSyncPending?
    private(set) var lastSuccessfulFingerprint: String?
    private(set) var lastAttemptFingerprint: String?
    private(set) var lastFailedFingerprint: String?
    private(set) var lastSyncAt: Date?
    private(set) var lastMessageCount = 0
    private(set) var inFlightFingerprint: String?
    /// 人工确认保存过之后置位：只有用户再次明确开启才解除
    private(set) var manualPause = false

    var isSaving: Bool { inFlightFingerprint != nil }

    mutating func beginChatGeneration(_ generation: Int) -> LiveChatAutoSyncEffect {
        self.generation = generation
        pending = nil
        inFlightFingerprint = nil
        lastSuccessfulFingerprint = nil
        lastFailedFingerprint = nil
        // Capture-level authorization, manual pause and minimum write interval survive.
        state = manualPause ? .pausedAfterManualSave : (enabled ? .waitingForChat : .disabled)
        return .cancelScheduled
    }

    // MARK: - 用户动作

    /// 新的 capture session：一切清零。自动同步回到「关闭」，上一轮的 fingerprint / pending 都不带过来。
    mutating func resetForNewSession(generation: Int) -> LiveChatAutoSyncEffect {
        self.generation = generation
        enabled = false
        manualPause = false
        pending = nil
        lastSuccessfulFingerprint = nil
        lastAttemptFingerprint = nil
        lastFailedFingerprint = nil
        lastSyncAt = nil
        lastMessageCount = 0
        inFlightFingerprint = nil
        state = .disabled
        return .cancelScheduled
    }

    /// 用户主动开关「自动同步给狗头军师」。
    mutating func setEnabled(
        _ newValue: Bool,
        messages: [LiveChatCandidate],
        now: Date,
        config: LiveChatAutoSyncConfiguration = .default
    ) -> LiveChatAutoSyncEffect {
        enabled = newValue
        guard newValue else {
            pending = nil
            state = .disabled
            return .cancelScheduled
        }
        // 明确重新开启：解除人工暂停，也允许对之前失败过的内容再试一次
        manualPause = false
        lastFailedFingerprint = nil
        return plan(messages: messages, now: now, config: config)
    }

    /// 时间线每次更新都进来一次。
    mutating func noteTimeline(
        messages: [LiveChatCandidate],
        now: Date,
        config: LiveChatAutoSyncConfiguration = .default
    ) -> LiveChatAutoSyncEffect {
        // 人工确认过的结果优先级最高：先看暂停，再看开关——
        // 否则「人工保存把开关关掉」之后，时间线一更新就会把状态显示成「已关闭」。
        if manualPause {
            pending = nil
            state = .pausedAfterManualSave
            return .cancelScheduled
        }
        guard enabled else {
            pending = nil
            state = .disabled
            return .cancelScheduled
        }
        return plan(messages: messages, now: now, config: config)
    }

    /// 排队的时刻到了：该写就写。
    mutating func fireDue(
        now: Date,
        config: LiveChatAutoSyncConfiguration = .default
    ) -> LiveChatAutoSyncEffect {
        guard enabled, !manualPause, let pending else { return .idle }
        guard now >= pending.deadline else { return .schedule(deadline: pending.deadline) }
        // 一次只允许一个写操作在飞；在飞的时候保留 pending，等它回来再决定
        guard inFlightFingerprint == nil else { return .idle }

        state = .syncing
        lastAttemptFingerprint = pending.snapshot.fingerprint
        inFlightFingerprint = pending.snapshot.fingerprint
        return .save(pending.snapshot)
    }

    /// 写盘结果回来。
    mutating func saveFinished(
        fingerprint: String,
        result: Result<LiveChatAutoSyncSnapshot, LiveChatAutoSyncFailure>,
        at now: Date
    ) -> LiveChatAutoSyncEffect {
        // 旧代际 / 旧任务的迟到回报：一概不认，更不许污染新 session 的统计
        guard fingerprint == inFlightFingerprint else { return .idle }
        inFlightFingerprint = nil
        if pending?.snapshot.fingerprint == fingerprint { pending = nil }

        switch result {
        case .success(let snapshot):
            lastSuccessfulFingerprint = fingerprint
            lastFailedFingerprint = nil
            lastSyncAt = now
            lastMessageCount = snapshot.count
            state = .synced(messageCount: snapshot.count, at: now)
        case .failure(let reason):
            lastFailedFingerprint = fingerprint
            state = .failed(reason.message)
        }

        // 写的过程中又攒了更新：继续按最新那份排一次
        if let pending, pending.snapshot.fingerprint != fingerprint, enabled, !manualPause {
            return .schedule(deadline: max(pending.deadline, now))
        }
        return .idle
    }

    /// 阶段 12C 的人工确认**成功**保存之后调用：立刻暂停自动同步并取消排队，
    /// 绝不让没经人工修正的时间线覆盖刚保存的人工结果。
    mutating func noteManualSaveSucceeded() -> LiveChatAutoSyncEffect {
        manualPause = true
        enabled = false
        pending = nil
        state = .pausedAfterManualSave
        return .cancelScheduled
    }

    /// 用户点「停止动态识别」。
    mutating func stop() -> LiveChatAutoSyncEffect {
        enabled = false
        manualPause = false
        pending = nil
        state = .disabled
        return .cancelScheduled
    }

    /// 「清空实时聊天」：只取消排队，不动已经共享出去的聊天。
    mutating func clearLiveChat() -> LiveChatAutoSyncEffect {
        pending = nil
        return .cancelScheduled
    }

    // MARK: - 决策

    private mutating func plan(
        messages: [LiveChatCandidate],
        now: Date,
        config: LiveChatAutoSyncConfiguration
    ) -> LiveChatAutoSyncEffect {
        switch LiveChatAutoSyncPayloadBuilder.build(from: messages, generation: generation, config: config) {
        case .blockedUnknown(let count):
            // unknown 整次拦住：旧共享聊天保持不动，等 unknown 消失再自动恢复
            pending = nil
            state = .blockedUnknown(count: count)
            return .cancelScheduled

        case .waitingForChat:
            pending = nil
            state = .waitingForChat
            return .cancelScheduled

        case .ready(let snapshot):
            if pending?.snapshot.fingerprint == snapshot.fingerprint {
                return .idle // Repeated frames cannot keep postponing the same save.
            }
            if snapshot.fingerprint == lastSuccessfulFingerprint {
                pending = nil
                state = .synced(messageCount: lastMessageCount, at: lastSyncAt ?? now)
                return .cancelScheduled
            }
            if snapshot.fingerprint == lastFailedFingerprint {
                pending = nil
                state = .failed("上一份内容没同步成功，等聊天变化或重新开启后再试")
                return .cancelScheduled
            }

            var deadline = now.addingTimeInterval(config.debounceInterval)
            if let lastSyncAt {
                deadline = max(deadline, lastSyncAt.addingTimeInterval(config.minimumSaveInterval))
            }
            pending = LiveChatAutoSyncPending(snapshot: snapshot, deadline: deadline)
            if inFlightFingerprint == nil { state = .scheduled }
            return .schedule(deadline: deadline)
        }
    }
}
