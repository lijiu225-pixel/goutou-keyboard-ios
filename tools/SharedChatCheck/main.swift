import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let writer = SharedChatStore(containerURL: directory)
let reader = SharedChatStore(containerURL: directory)
let missing = try reader.load()
expect(missing == nil, "Missing cache must be empty")
let now = Date(timeIntervalSince1970: 1_700_000_000)
let snapshot = ChatSnapshot(updatedAt: now, messages: [
    ChatMessage(role: .other, text: "你好", timestamp: nil),
    ChatMessage(role: .me, text: "你好啊", timestamp: now)
])
try writer.save(snapshot)
let loaded = try reader.load()
expect(loaded == snapshot, "Independent readers must see the same Chinese text, roles and dates")
expect(!snapshot.isExpired(now: now.addingTimeInterval(29)), "Fresh cache")
expect(snapshot.isExpired(now: now.addingTimeInterval(31)), "Expired cache")
expect(snapshot.isExpired(now: now.addingTimeInterval(-60)), "Clock rollback must not look fresh")
let replacement = ChatSnapshot(updatedAt: now, messages: [.init(role: .unknown, text: "新内容", timestamp: nil)])
try writer.save(replacement)
let replaced = try reader.load()
expect(replaced == replacement, "Save replaces rather than appends old chats")
try Data("invalid JSON".utf8).write(to: directory.appendingPathComponent("latest_chat.json"))
do {
    _ = try reader.load()
    fatalError("Corrupt cache must report an error")
} catch SharedChatStoreError.invalidData { }
try writer.clear()
try writer.clear()
let cleared = try reader.load()
expect(cleared == nil, "Clear must be idempotent and visible to another reader")
let unavailable = SharedChatStore(containerURL: nil)
do {
    _ = try unavailable.load()
    fatalError("Missing entitlement must not fall back to a private sandbox")
} catch SharedChatStoreError.containerUnavailable { }
print("SharedChatCheck passed")
