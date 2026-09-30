import Foundation

/// At most one screen buffer may wait for MainActor delivery; no frame task backlog.
final class LiveFrameDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !pending else { return false }
        pending = true
        return true
    }
    func release() { lock.lock(); defer { lock.unlock() }; pending = false }
}

/// Production pipeline also used by the scene regression tests.
/// 门控诊断快照：只给主 App 的调试页看，**不含聊天正文**。
struct LiveSceneDiagnostics: Equatable {
    var confidence: CGFloat
    var hasNavigationBar: Bool
    var hasInputBar: Bool
    var messageRowCount: Int
    var leftCount: Int
    var rightCount: Int
    var centeredCount: Int
    var tabBarLineCount: Int
    var enterStreak: Int
    var exitStreak: Int
    var verdict: ChatSceneVerdict
}

struct LiveChatScenePipeline {
    private var gate = ChatSceneGate()
    private var system = LiveChatSystem()
    private var geometry = LiveChatGeometryConfiguration.default
    private(set) var chatGeneration = 0
    private(set) var verdict: ChatSceneVerdict = .unknown
    private(set) var allowsFullRecognition = false
    private(set) var startsNewSession = false
    /// 最近一帧的门控证据：只给诊断界面看，**不含任何聊天正文**。
    private(set) var lastEvidence: ChatSceneEvidence?
    var enterStreak: Int { gate.enterStreak }
    var exitStreak: Int { gate.exitStreak }
    var hasConfirmedTitle: Bool { gate.hasConfirmedTitle }

    /// 诊断快照：哪一项没满足，一眼能看出来。
    var diagnostics: LiveSceneDiagnostics? {
        guard let evidence = lastEvidence else { return nil }
        return LiveSceneDiagnostics(
            confidence: evidence.confidence,
            hasNavigationBar: evidence.hasNavigationBar,
            hasInputBar: evidence.hasInputBar,
            messageRowCount: evidence.messageRowCount,
            leftCount: evidence.leftMessageCount,
            rightCount: evidence.rightMessageCount,
            centeredCount: evidence.centeredMessageCount,
            tabBarLineCount: evidence.tabBarLineCount,
            enterStreak: gate.enterStreak,
            exitStreak: gate.exitStreak,
            verdict: verdict
        )
    }

    mutating func reset() {
        gate.reset()
        verdict = .unknown
        allowsFullRecognition = false
        lastEvidence = nil
        newChat()
    }

    mutating func detect(_ evidence: ChatSceneEvidence) {
        lastEvidence = evidence
        geometry.topInsetRatio = ChatSceneGateConfiguration.default.bodyTopRatio
        geometry.bottomInsetRatio = evidence.inputTopRatio.map { 1 - $0 } ?? LiveChatGeometryConfiguration.default.bottomInsetRatio
        let decision = gate.update(isChatFrame: ChatSceneDetector.isChatScene(evidence),
                                   titleFingerprint: evidence.topBarFingerprint)
        verdict = decision.verdict
        startsNewSession = decision.startsNewSession
        allowsFullRecognition = gate.allowsSubmission
        if startsNewSession { newChat() }
    }

    mutating func ingest(_ observations: [LiveOCRObservation], at now: Date) -> LiveChatSnapshot {
        guard allowsFullRecognition else { return system.snapshot() }
        let snapshot = system.ingest(observations: observations, timestamp: now, generation: chatGeneration, config: geometry)
        // No reliable overlap: isolate the new visible chat, even with the same/missing title.
        if snapshot.showsDiscontinuity {
            newChat()
            startsNewSession = true
            return system.ingest(observations: observations, timestamp: now, generation: chatGeneration, config: geometry)
        }
        return snapshot
    }

    func snapshot() -> LiveChatSnapshot { system.snapshot() }

    private mutating func newChat() {
        chatGeneration += 1
        system.reset(generation: chatGeneration)
    }
}
