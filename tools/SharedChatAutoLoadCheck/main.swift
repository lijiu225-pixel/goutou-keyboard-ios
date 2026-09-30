import Foundation

var checks = 0
func expect(_ ok: Bool, _ label: String) {
    checks += 1
    if !ok { fatalError("SharedChatAutoLoadCheck: \(label)") }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let store = SharedChatStore(testContainer: root)
let a = [GoutouChatClipboardMessage(role: .other, text: "合成问题"),
         GoutouChatClipboardMessage(role: .me, text: "合成回答")]
try store.save(GoutouChatClipboardPayload(messages: a))
var chat = RecognizedChatSession()
var analysis = RecognizedChatAnalysisSession()
var reads = 0
var cancellations = 0
func load() -> SharedChatAutoLoadResult {
    SharedChatAutoLoader.load(read: { reads += 1; return try store.read() },
        chat: &chat, analysis: &analysis, cancelPrevious: { cancellations += 1 })
}
expect(load() == .adopted(2), "first open adopts without preview/use")
expect(chat.active?.messages == a, "actual store read adopted")
expect(analysis.state == .idle, "no analysis starts on load")
let result = RecognizedChatResult(analysis: "合成分析", tone: "合成状态", replies: ["答一", "答二", "答三"])
let config = GoutouConfig(baseURL: "https://example.invalid/v1", model: "synthetic", apiKey: "")
guard case .started(let oldGeneration) = analysis.begin(hasFullAccess: true, config: config,
    skillAvailable: true, context: chat.active) else { fatalError("cannot start synthetic analysis") }
analysis.complete(generation: oldGeneration, result: .success(result))
let before = analysis
let cancelBefore = cancellations
expect(load() == .unchanged, "same fingerprint is no-op")
expect(analysis.state == before.state && analysis.generation == before.generation, "result and generation preserved")
expect(cancellations == cancelBefore, "same chat does not cancel")
for error in [SharedChatStoreError.notSaved, .containerUnavailable, .damagedJSON, .readFailed,
              .unsupportedFormat, .invalidTime, .invalidChat(.unsupportedVersion(999))] {
    expect(SharedChatAutoLoader.load(read: { throw error }, chat: &chat, analysis: &analysis,
        cancelPrevious: { cancellations += 1 }) == .failed, "read failure handled")
    expect(chat.active?.messages == a && analysis.state == before.state, "failure is non-destructive")
}
let variations = [
    [GoutouChatClipboardMessage(role: .other, text: "合成新问题"), a[1]],
    [GoutouChatClipboardMessage(role: .me, text: "合成新问题"), a[1]],
    [a[1], GoutouChatClipboardMessage(role: .me, text: "合成新问题")]
]
for messages in variations {
    guard case .started(let generation) = analysis.begin(hasFullAccess: true, config: config,
        skillAvailable: true, context: chat.active) else { fatalError("synthetic analysis") }
    let priorCancel = cancellations
    try store.save(GoutouChatClipboardPayload(messages: messages))
    expect(load() == .adopted(2), "text/role/order change adopts")
    expect(cancellations == priorCancel + 1, "old task cancelled")
    expect(analysis.generation != generation && analysis.state == .idle, "old results invalidated")
    analysis.complete(generation: generation, result: .success(result))
    expect(analysis.state == .idle, "late response rejected")
}
chat = RecognizedChatSession()
expect(load() == .adopted(2), "new keyboard instance restores from disk")
expect(reads == 6, "only event-driven reads")
let source = try String(contentsOfFile: "Keyboard/SharedChatAutoLoader.swift", encoding: .utf8)
for token in ["GoutouAIClient", "URLSession", "insertText", "textDocumentProxy", "Timer"] {
    expect(!source.contains(token), "loader has no network/input/polling capability")
}
print("SharedChatAutoLoadCheck passed (\(checks) assertions)")
