import CoreGraphics
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
    /// OCR can continue while submission and automatic synchronization are held.
    private(set) var shouldRunOCR = false
    private(set) var startsNewSession = false
    private struct PendingFrame {
        var observations: [LiveOCRObservation]
        var timestamp: Date
        var geometry: LiveChatGeometryConfiguration
        var title: String?
    }
    private var pendingFrames: [PendingFrame] = []
    var pendingFrameCount: Int { pendingFrames.count }
    var pendingObservationCount: Int { pendingFrames.reduce(0) { $0 + $1.observations.count } }
    var pendingCharacterCount: Int { pendingFrames.reduce(0) { total, frame in
        total + frame.observations.reduce(0) { $0 + $1.text.count }
    } }
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
        shouldRunOCR = false
        startsNewSession = false
        discardPendingRecognition()
        lastEvidence = nil
        newChat()
    }

    mutating func detect(_ evidence: ChatSceneEvidence) {
        lastEvidence = evidence
        geometry.topInsetRatio = ChatSceneGateConfiguration.default.bodyTopRatio
        geometry.bottomInsetRatio = evidence.inputTopRatio.map { 1 - $0 } ?? LiveChatGeometryConfiguration.default.bottomInsetRatio
        let clearlyNonChat = ChatSceneDetector.isClearlyNonChatScene(evidence)
        let decision = gate.update(isChatFrame: ChatSceneDetector.isChatScene(evidence),
                                   titleFingerprint: evidence.topBarFingerprint,
                                   isClearlyNonChatFrame: clearlyNonChat)
        verdict = decision.verdict
        startsNewSession = decision.startsNewSession
        allowsFullRecognition = gate.allowsSubmission
        shouldRunOCR = !clearlyNonChat
        if clearlyNonChat { discardPendingRecognition() }
        if startsNewSession { discardPendingRecognition(); newChat() }
    }

    mutating func ingest(_ observations: [LiveOCRObservation], at now: Date) -> LiveChatSnapshot {
        guard shouldRunOCR else { return system.snapshot() }
        guard allowsFullRecognition else {
            buffer(observations, at: now)
            return system.snapshot()
        }
        // Replay only frames whose ownership is corroborated by this confirmed frame.
        // Two nontrivial, role-confirmed messages must match; a lone "哈哈" is not identity.
        let confirmed = candidates(observations, at: now, geometry: geometry)
        for frame in pendingFrames {
            guard frame.title == nil || frame.title == lastEvidence?.topBarFingerprint else { continue }
            let visible = candidates(frame.observations, at: frame.timestamp, geometry: frame.geometry)
            guard reliableOverlap(visible, confirmed) else { continue }
            var trial = system
            let replay = trial.ingest(observations: frame.observations, timestamp: frame.timestamp,
                                      generation: chatGeneration, config: frame.geometry)
            // Never let a cached frame rotate or contaminate a different conversation.
            if !replay.showsDiscontinuity { system = trial }
        }
        discardPendingRecognition()
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

    mutating func discardPendingRecognition() { pendingFrames.removeAll() }

    private mutating func buffer(_ observations: [LiveOCRObservation], at now: Date) {
        let limits = ChatSceneGateConfiguration.default
        let filtered = LiveChatViewportFilter.filter(observations, config: geometry)
        guard !filtered.isEmpty,
              filtered.count <= limits.maximumPendingObservations,
              filtered.reduce(0, { $0 + $1.text.count }) <= limits.maximumPendingCharacters else { return }
        pendingFrames.append(PendingFrame(observations: filtered, timestamp: now,
                                          geometry: geometry, title: lastEvidence?.topBarFingerprint))
        while pendingFrames.count > limits.maximumPendingFrames
            || pendingObservationCount > limits.maximumPendingObservations
            || pendingCharacterCount > limits.maximumPendingCharacters {
            pendingFrames.removeFirst()
        }
    }

    private func candidates(_ observations: [LiveOCRObservation], at now: Date,
                            geometry: LiveChatGeometryConfiguration) -> [LiveChatCandidate] {
        LiveChatBlockGrouper.group(LiveChatViewportFilter.filter(observations, config: geometry),
                                  config: geometry, timestamp: now)
    }

    private func reliableOverlap(_ lhs: [LiveChatCandidate], _ rhs: [LiveChatCandidate]) -> Bool {
        let left = lhs.filter { ($0.role == .me || $0.role == .other) && $0.normalizedText.count >= 4 }
        let right = rhs.filter { ($0.role == .me || $0.role == .other) && $0.normalizedText.count >= 4 }
        guard left.count >= 2, right.count >= 2 else { return false }
        return (LiveChatTimeline.bestOverlap(visible: left, timeline: right, config: geometry)?.length ?? 0) >= 2
    }

    private mutating func newChat() {
        chatGeneration += 1
        system.reset(generation: chatGeneration)
    }
}
