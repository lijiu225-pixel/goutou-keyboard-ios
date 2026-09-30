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
struct LiveChatScenePipeline {
    private var gate = ChatSceneGate()
    private var system = LiveChatSystem()
    private var geometry = LiveChatGeometryConfiguration.default
    private(set) var chatGeneration = 0
    private(set) var verdict: ChatSceneVerdict = .unknown
    private(set) var allowsFullRecognition = false
    private(set) var startsNewSession = false

    mutating func reset() {
        gate.reset()
        verdict = .unknown
        allowsFullRecognition = false
        newChat()
    }

    mutating func detect(_ evidence: ChatSceneEvidence) {
        geometry.topInsetRatio = ChatSceneGateConfiguration.default.topInsetRatio
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
