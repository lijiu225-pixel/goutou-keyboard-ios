import Foundation

struct SharedChatSnapshot: Equatable {
    let messages: [GoutouChatClipboardMessage]
    let updatedAt: Date

    func isOlderThanThirtyMinutes(now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) > 30 * 60
    }
}

enum SharedChatStoreError: LocalizedError, Equatable {
    case containerUnavailable, notSaved, readFailed, damagedJSON, unsupportedFormat
    case invalidTime, fileTooLarge, saveFailed, clearFailed
    case invalidChat(GoutouChatClipboardError)

    var errorDescription: String? {
        switch self {
        case .containerUnavailable: return "共享容器不可用，请检查重签后的 App Group 权限。"
        case .notSaved: return "尚未保存聊天，请先在主 App 点「保存给狗头军师」。"
        case .readFailed: return "共享聊天文件读取失败，请重新保存后再试。"
        case .damagedJSON: return "共享聊天 JSON 损坏，请在主 App 重新保存。"
        case .unsupportedFormat: return "共享聊天的 format 不支持，请在主 App 重新保存。"
        case .invalidTime: return "共享聊天的时间元数据异常，请在主 App 重新保存。"
        case .fileTooLarge: return "共享聊天文件体量超过限制，请减少聊天内容。"
        case .saveFailed: return "保存失败，上一份共享聊天未被替换，请检查容器写入权限。"
        case .clearFailed: return "清除共享聊天失败，请检查容器权限后重试。"
        case .invalidChat(let error):
            // Reuse the codec's validation, but keep file errors independent of clipboard wording.
            switch error {
            case .unsupportedVersion(let v): return "共享聊天版本 v\(v) 不支持，当前只支持 v1。"
            case .invalidVersionType: return "共享聊天的 version 必须是整数。"
            case .emptyMessages: return "聊天消息为空，不能保存或预览。"
            case .tooManyMessages(let limit): return "聊天消息超过 \(limit) 条限制。"
            case .emptyMessage(let index): return "第 \(index) 条聊天正文为空。"
            case .messageTooLong(let index, _, let limit): return "第 \(index) 条聊天超过 \(limit) 字限制。"
            case .invalidRole(let index, _): return "第 \(index) 条聊天归属无效，只支持「我 / 对方」。"
            case .inputTooLong: return "聊天内容总长度超过限制。"
            case .malformedJSON: return "共享聊天 JSON 结构损坏。"
            case .notOurFormat: return "共享聊天缺少 format 或 version 标记。"
            }
        }
    }
}

/// Both processes use the same codec and path. This provider-owned group is NOT isolated.
struct SharedChatStore {
    // File bytes are bounded before allocating/parsing. Four UTF-8 bytes per codec character.
    static let maximumFileBytes = GoutouChatClipboardCodec.maxEncodedLength * 4
    private let resolveContainer: () -> URL?

    init() {
        resolveContainer = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupID)
        }
    }

    /// Filesystem tests only; does not simulate iOS entitlements or full access.
    init(testContainer: URL?) { resolveContainer = { testContainer } }

    private func fileURL() throws -> URL {
        guard let container = resolveContainer() else { throw SharedChatStoreError.containerUnavailable }
        return container.appendingPathComponent(SharedConstants.chatDirectory, isDirectory: true)
            .appendingPathComponent(SharedConstants.latestChatFilename)
    }

    @discardableResult
    func save(_ payload: GoutouChatClipboardPayload, updatedAt: Date = Date()) throws -> SharedChatSnapshot {
        let url = try fileURL()
        guard updatedAt.timeIntervalSince1970.isFinite else { throw SharedChatStoreError.invalidTime }
        let text: String
        do { text = try GoutouChatClipboardCodec.encode(payload) }
        catch let error as GoutouChatClipboardError { throw SharedChatStoreError.invalidChat(error) }
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw SharedChatStoreError.damagedJSON
        }
        let formatter = Self.timeFormatter(fractional: true)
        object["updatedAt"] = formatter.string(from: updatedAt)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            throw SharedChatStoreError.saveFailed
        }
        // Validate exactly what will be persisted before touching the previous snapshot.
        let snapshot = try Self.decode(data)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { throw SharedChatStoreError.saveFailed }
        return snapshot
    }

    func read() throws -> SharedChatSnapshot {
        let url = try fileURL()
        let data: Data
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attrs[.size] as? NSNumber,
                  size.int64Value <= Int64(Self.maximumFileBytes) else { throw SharedChatStoreError.fileTooLarge }
            // Bounded read also protects against a file growing after the size check.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        } catch let error as SharedChatStoreError { throw error }
        catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError) {
                throw SharedChatStoreError.notSaved
            }
            throw SharedChatStoreError.readFailed
        }
        return try Self.decode(data)
    }

    func clear() throws {
        let url = try fileURL()
        do { try FileManager.default.removeItem(at: url) }
        catch {
            let nsError = error as NSError
            // Clearing an absent snapshot is idempotent. Permission errors are never hidden.
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileNoSuchFileError { return }
            throw SharedChatStoreError.clearFailed
        }
    }

    private static func decode(_ data: Data) throws -> SharedChatSnapshot {
        guard data.count <= maximumFileBytes else { throw SharedChatStoreError.fileTooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw SharedChatStoreError.damagedJSON }
        guard text.count <= GoutouChatClipboardCodec.maxEncodedLength else {
            throw SharedChatStoreError.invalidChat(.inputTooLong(length: text.count, limit: GoutouChatClipboardCodec.maxEncodedLength))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SharedChatStoreError.damagedJSON
        }
        guard object["format"] as? String == GoutouChatClipboardPayload.format else {
            throw SharedChatStoreError.unsupportedFormat
        }
        let payload: GoutouChatClipboardPayload
        do { payload = try GoutouChatClipboardCodec.decode(text) }
        catch let error as GoutouChatClipboardError { throw SharedChatStoreError.invalidChat(error) }
        guard let rawTime = object["updatedAt"] as? String, rawTime.utf8.count <= 64,
              let time = timeFormatter(fractional: true).date(from: rawTime)
                ?? timeFormatter(fractional: false).date(from: rawTime),
              time.timeIntervalSince1970.isFinite else { throw SharedChatStoreError.invalidTime }
        return SharedChatSnapshot(messages: payload.messages, updatedAt: time)
    }

    private static func timeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }
}
