import Foundation

var checks = 0
func expect(_ value: Bool, _ description: String) {
    checks += 1
    if !value { fatalError("SharedChatStoreCheck: \(description)") }
}
func expectError(_ expected: SharedChatStoreError, _ description: String, _ work: () throws -> Void) {
    do { try work(); expect(false, description) }
    catch let error as SharedChatStoreError { expect(error == expected, description) }
    catch { expect(false, "Unexpected error: \(description)") }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("SharedChatStoreCheck-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let writer = SharedChatStore(testContainer: root)
let reader = SharedChatStore(testContainer: root)
let directory = root.appendingPathComponent(SharedConstants.chatDirectory)
let file = directory.appendingPathComponent(SharedConstants.latestChatFilename)
let time = Date(timeIntervalSince1970: 1_700_000_000.125)
let messages = [GoutouChatClipboardMessage(role: .other, text: "测试第一条"),
                GoutouChatClipboardMessage(role: .me, text: "测试第二条\n下一行")]
let payload = GoutouChatClipboardPayload(messages: messages)

expectError(.notSaved, "No file") { _ = try reader.read() }
try writer.clear()
let saved = try writer.save(payload, updatedAt: time)
let loaded = try reader.read()
expect(loaded == saved, "Another instance reads identical snapshot")
expect(loaded.messages == messages, "Roles, text, line breaks and order")
expect(abs(loaded.updatedAt.timeIntervalSince(time)) < 0.001, "Millisecond timestamp")
expect(!loaded.isOlderThanThirtyMinutes(now: time.addingTimeInterval(1799.999)), "Before expiry")
expect(!loaded.isOlderThanThirtyMinutes(now: time.addingTimeInterval(1800)), "Exactly thirty minutes")
expect(loaded.isOlderThanThirtyMinutes(now: time.addingTimeInterval(1800.001)), "After thirty minutes")
expect(!loaded.isOlderThanThirtyMinutes(now: time.addingTimeInterval(-1)), "Clock earlier than timestamp")
let clipboard = try GoutouChatClipboardCodec.decode(String(contentsOf: file, encoding: .utf8))
expect(clipboard.messages == messages, "Saved format remains clipboard compatible")

let replacement = GoutouChatClipboardPayload(messages: [.init(role: .me, text: "第二次保存")])
try writer.save(replacement, updatedAt: time.addingTimeInterval(1))
expect(try reader.read().messages == replacement.messages, "Second save replaces first")
let oldData = try Data(contentsOf: file)
expectError(.invalidChat(.emptyMessages), "Empty save rejected") { try writer.save(.init(messages: [])) }
expect(try Data(contentsOf: file) == oldData, "Validation failure preserves previous bytes")

// A real filesystem write failure: the directory cannot create the atomic replacement.
try fm.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: directory.path)
expectError(.saveFailed, "Read-only directory rejects atomic replacement") { try writer.save(payload, updatedAt: time) }
expect(try Data(contentsOf: file) == oldData, "Failed atomic write leaves previous snapshot intact")
expect(try reader.read().messages == replacement.messages, "Previous snapshot still readable")
try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: directory.path)

func fixture(_ overrides: [String: Any]) throws {
    var object: [String: Any] = ["format": "goutou-chat", "version": 1,
        "updatedAt": "2023-11-14T22:13:20.125Z", "messages": [["role": "me", "text": "测试"]]]
    for (key, value) in overrides { object[key] = value }
    try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
}
try fixture(["messages": []])
expectError(.invalidChat(.emptyMessages), "Empty file messages") { _ = try reader.read() }
try fixture(["messages": [["role": "unknown", "text": "测试"]]])
expectError(.invalidChat(.invalidRole(index: 1, value: "unknown")), "Unknown role") { _ = try reader.read() }
try fixture(["version": 2])
expectError(.invalidChat(.unsupportedVersion(2)), "Unsupported integer version") { _ = try reader.read() }
for version in [true, "1", 1.5, NSNull()] as [Any] {
    try fixture(["version": version])
    expectError(.invalidChat(.invalidVersionType), "Invalid version type") { _ = try reader.read() }
}
try fixture(["format": "other"])
expectError(.unsupportedFormat, "Unsupported format") { _ = try reader.read() }
for timestamp in ["broken", 123, NSNull(), ""] as [Any] {
    try fixture(["updatedAt": timestamp])
    expectError(.invalidTime, "Invalid timestamp") { _ = try reader.read() }
}
try fixture(["updatedAt": "2023-11-14T22:13:20Z"])
expect(try reader.read().updatedAt == Date(timeIntervalSince1970: 1_700_000_000), "ISO8601 without fractions")
try Data("{broken".utf8).write(to: file)
expectError(.damagedJSON, "Damaged JSON") { _ = try reader.read() }
try Data([0xFF]).write(to: file)
expectError(.damagedJSON, "Invalid UTF8") { _ = try reader.read() }
try fixture(["messages": [["role": "me", "text": "  "]]])
expectError(.invalidChat(.emptyMessage(index: 1)), "Blank body") { _ = try reader.read() }
try fixture(["messages": [["role": "me", "text": String(repeating: "x", count: 2001)]]])
expectError(.invalidChat(.messageTooLong(index: 1, length: 2001, limit: 2000)), "Message length limit") { _ = try reader.read() }
try fixture(["messages": Array(repeating: ["role": "me", "text": "测试"], count: 201)])
expectError(.invalidChat(.tooManyMessages(limit: 200)), "Message count limit") { _ = try reader.read() }
try Data(repeating: 32, count: GoutouChatClipboardCodec.maxEncodedLength + 1).write(to: file)
expectError(.invalidChat(.inputTooLong(length: GoutouChatClipboardCodec.maxEncodedLength + 1, limit: GoutouChatClipboardCodec.maxEncodedLength)), "Total text limit before JSON parsing") { _ = try reader.read() }
try Data(repeating: 32, count: SharedChatStore.maximumFileBytes + 1).write(to: file)
expectError(.fileTooLarge, "File size limit before read") { _ = try reader.read() }

try writer.save(payload, updatedAt: time)
try writer.clear()
expectError(.notSaved, "Read after clear") { _ = try reader.read() }
let unavailable = SharedChatStore(testContainer: nil)
expectError(.containerUnavailable, "No container read") { _ = try unavailable.read() }
expectError(.containerUnavailable, "No container save") { try unavailable.save(payload) }
expectError(.containerUnavailable, "No container clear") { try unavailable.clear() }
// Existing file with no read permission must not be reported as missing.
try writer.save(payload, updatedAt: time)
try fm.setAttributes([.posixPermissions: NSNumber(value: 0)], ofItemAtPath: file.path)
expectError(.readFailed, "File read denied") { _ = try reader.read() }
try fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: file.path)
try fm.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: directory.path)
expectError(.clearFailed, "Delete denied") { try writer.clear() }
try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: directory.path)
try writer.clear()
print("SharedChatStoreCheck passed (\(checks) assertions; temporary filesystem only)")
