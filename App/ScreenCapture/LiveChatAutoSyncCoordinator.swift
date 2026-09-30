import Foundation

/// 阶段 12D 的执行层：把纯决策（`LiveChatAutoSyncSession`）变成真正的计时器与写盘。
///
/// 只在聊天引擎所在的那条 OCR 串行队列上访问，所以不需要额外加锁；
/// 状态变化通过 `onStateChange` 交给持有者切回主线程发布。
/// 写盘继续用**现有** SharedChatStore：没有第二套存储、没有私有通道。
final class LiveChatAutoSyncCoordinator {

    private let store: SharedChatStore
    private let config: LiveChatAutoSyncConfiguration
    private let queue: DispatchQueue
    private var session = LiveChatAutoSyncSession()
    private var scheduled: DispatchWorkItem?

    /// 状态变化回调：(状态, 最后成功同步时间, 最后成功条数)
    var onStateChange: ((LiveChatAutoSyncState, Date?, Int) -> Void)?

    init(
        store: SharedChatStore = SharedChatStore(),
        config: LiveChatAutoSyncConfiguration = .default,
        queue: DispatchQueue
    ) {
        self.store = store
        self.config = config
        self.queue = queue
    }

    // MARK: - 给持有者读的（都在同一队列上）

    var state: LiveChatAutoSyncState { session.state }
    var lastSyncAt: Date? { session.lastSyncAt }
    var lastMessageCount: Int { session.lastMessageCount }
    var isEnabled: Bool { session.enabled }

    // MARK: - 用户 / 生命周期动作

    /// 新的 capture session：自动同步回到「关闭」，旧 fingerprint / pending 一律不带过来。
    func resetForNewSession(generation: Int) {
        cancelScheduled()
        apply(session.resetForNewSession(generation: generation), now: Date())
    }

    /// 用户主动开关「自动同步给狗头军师」。
    func setEnabled(_ enabled: Bool, messages: [LiveChatCandidate], now: Date = Date()) {
        cancelScheduled()
        apply(session.setEnabled(enabled, messages: messages, now: now, config: config), now: now)
    }

    /// 时间线每次更新都进来一次。
    func noteTimeline(_ messages: [LiveChatCandidate], generation: Int, now: Date = Date()) {
        apply(session.noteTimeline(messages: messages, now: now, config: config), now: now)
    }

    /// 用户 Stop：取消排队、回到关闭，但**不**删除已经共享成功的聊天。
    func stop() {
        cancelScheduled()
        apply(session.stop(), now: Date())
    }

    /// 「清空实时聊天」：取消排队，但不动 SharedChatStore 里上一份聊天。
    func clearLiveChat() {
        cancelScheduled()
        apply(session.clearLiveChat(), now: Date())
    }

    /// 阶段 12C 人工确认保存**成功**之后：立即暂停自动同步，防止人工结果被自动覆盖。
    func noteManualSaveSucceeded() {
        cancelScheduled()
        apply(session.noteManualSaveSucceeded(), now: Date())
    }

    // MARK: - 内部

    private func apply(_ effect: LiveChatAutoSyncEffect, now: Date) {
        switch effect {
        case .idle:
            break

        case .cancelScheduled:
            cancelScheduled()
            publish()

        case .schedule(let deadline):
            cancelScheduled()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.scheduled = nil
                self.apply(self.session.fireDue(now: Date(), config: self.config), now: Date())
            }
            scheduled = item
            queue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSince(now)), execute: item)
            publish()

        case .save(let snapshot):
            publish()
            performSave(snapshot)
        }
    }

    private func performSave(_ snapshot: LiveChatAutoSyncSnapshot) {
        let result: Result<LiveChatAutoSyncSnapshot, String>
        do {
            // updatedAt 用 SharedChatStore 的默认值 = 本次真正写入的时刻
            let saved = try store.save(GoutouChatClipboardPayload(messages: snapshot.messages))
            result = .success(LiveChatAutoSyncSnapshot(
                messages: saved.messages,
                fingerprint: snapshot.fingerprint,
                generation: snapshot.generation
            ))
        } catch {
            result = .failure(failureReason(error))
        }
        let next = session.saveFinished(fingerprint: snapshot.fingerprint, result: result, at: Date())
        publish()
        apply(next, now: Date())
    }

    /// 失败原因只说人话，不吐沙盒路径、不吐聊天正文。
    private func failureReason(_ error: Error) -> String {
        if let reviewError = error as? LiveChatReviewError, let text = reviewError.errorDescription {
            return text
        }
        if let storeError = error as? SharedChatStoreError, let text = storeError.errorDescription {
            return text
        }
        return "写入共享聊天失败，请稍后重试。"
    }

    private func cancelScheduled() {
        scheduled?.cancel()
        scheduled = nil
    }

    private func publish() {
        onStateChange?(session.state, session.lastSyncAt, session.lastMessageCount)
    }
}
