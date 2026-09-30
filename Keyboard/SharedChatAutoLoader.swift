import Foundation

enum SharedChatAutoLoadResult: Equatable {
    case adopted(Int)
    case unchanged
    case failed
}

/// Event-only, local loading. The injected read uses the complete SharedChatStore validation.
/// There is deliberately no request or insertion capability in this component.
enum SharedChatAutoLoader {
    static func load(
        read: () throws -> SharedChatSnapshot,
        chat: inout RecognizedChatSession,
        analysis: inout RecognizedChatAnalysisSession,
        cancelPrevious: () -> Void
    ) -> SharedChatAutoLoadResult {
        guard let snapshot = try? read(), !snapshot.messages.isEmpty else { return .failed }
        let fingerprint = SharedChatFingerprint.make(messages: snapshot.messages)
        if let active = chat.active,
           SharedChatFingerprint.make(messages: active.messages) == fingerprint {
            return .unchanged
        }
        cancelPrevious()
        analysis.invalidate()
        chat.adoptActive(snapshot)
        return .adopted(snapshot.messages.count)
    }
}
