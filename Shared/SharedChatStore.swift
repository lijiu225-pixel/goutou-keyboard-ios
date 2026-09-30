import Foundation

enum SharedChatStoreError: LocalizedError {
    case containerUnavailable
    case invalidData

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return "共享聊天不可用，请检查 App Group 签名与键盘完全访问权限。"
        case .invalidData:
            return "聊天缓存格式异常，请清空缓存后重试。"
        }
    }
}

/// Both targets compile this same implementation. No private-container fallback,
/// screenshot storage, logging of chat content, or network activity.
struct SharedChatStore {
    static let groupIdentifier = "group.com.example.goutouinput.shared"
    private let containerURL: URL?

    init() {
        containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.groupIdentifier
        )
    }

    /// Allows the disk contract to be tested without an iOS signing identity.
    init(containerURL: URL?) {
        self.containerURL = containerURL
    }

    private func fileURL() throws -> URL {
        guard let containerURL = containerURL else {
            throw SharedChatStoreError.containerUnavailable
        }
        return containerURL.appendingPathComponent("latest_chat.json")
    }

    func save(_ snapshot: ChatSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(snapshot)
        // Atomic replacement prevents readers in another process seeing partial JSON.
        #if os(iOS)
        try data.write(to: fileURL(), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: fileURL(), options: .atomic)
        #endif
    }

    func load() throws -> ChatSnapshot? {
        let url = try fileURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError {
            // Read directly rather than check-then-read; clearing can race with reads.
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return nil
            }
            throw error
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(ChatSnapshot.self, from: data)
        } catch {
            throw SharedChatStoreError.invalidData
        }
    }

    func clear() throws {
        do {
            try FileManager.default.removeItem(at: fileURL())
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { return }
            throw error
        }
    }
}
