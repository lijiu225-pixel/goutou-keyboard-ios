import Foundation

/// 确认页里的一条消息：从 Live Timeline **冻结**出来的草稿。
///
/// 只放内存：不落盘、不写偏好设置、不进 App Group；只有用户点保存时才交给 SharedChatStore。
struct LiveChatReviewMessage: Identifiable, Equatable {
    let id: UUID
    /// 冻结时的原始角色：只读，用来说明这条是从哪儿来的
    let originalRole: LiveChatRole
    /// 用户改过的角色：只允许 我 / 对方 / 未确定
    var role: LiveChatRole
    /// 用户最终编辑过的正文（保存的就是它，不会被原始 OCR 覆盖）
    var text: String
    /// 是否保留
    var isIncluded: Bool

    /// stage 12B 的 system（时间 / 撤回提示这类）不参与正式聊天。
    var isSystem: Bool { originalRole == .system }
}

/// 一份冻结的确认草稿。
///
/// 生成之后，Live Timeline 再新增多少消息都不会影响它——用户正在改第 5 条时，
/// 绝不会突然变成第 6 条或内容被换掉。
struct LiveChatReviewDraft: Equatable {
    private(set) var messages: [LiveChatReviewMessage]

    init(timeline: [LiveChatCandidate]) {
        messages = timeline.map { candidate in
            LiveChatReviewMessage(
                id: UUID(),
                originalRole: candidate.role,
                // me / other / unknown 原样搬过来：unknown 绝不偷偷变成某一方
                role: candidate.role,
                text: candidate.text,
                // system 默认排除，其它默认保留
                isIncluded: candidate.role != .system
            )
        }
    }

    var includedCount: Int { messages.filter(\.isIncluded).count }
    var systemCount: Int { messages.filter(\.isSystem).count }

    /// 保留了、但角色仍是「未确定」的条数：这些必须由用户处理完才能保存。
    var unresolvedUnknownCount: Int {
        messages.filter { $0.isIncluded && !$0.isSystem && $0.role == .unknown }.count
    }

    mutating func update(id: UUID, role: LiveChatRole? = nil, text: String? = nil, isIncluded: Bool? = nil) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        if let role, role != .system { messages[index].role = role }
        if let text { messages[index].text = text }
        if let isIncluded, !messages[index].isSystem { messages[index].isIncluded = isIncluded }
    }

    /// 真正要写进正式共享聊天的内容：只保留 me / other、正文非空、**顺序不变**。
    func savableMessages() -> [GoutouChatClipboardMessage] {
        messages.compactMap { message in
            guard message.isIncluded, !message.isSystem else { return nil }
            // unknown 在这里落空：正式契约只认 me / other
            guard let role = GoutouChatRole(rawValue: message.role.rawValue) else { return nil }
            let text = message.text.trimmed
            guard !text.isEmpty else { return nil }
            return GoutouChatClipboardMessage(role: role, text: text)
        }
    }

    /// 保存前的把关：把「为什么现在不能保存」讲清楚。
    func validate() -> LiveChatReviewError? {
        if messages.isEmpty { return .noMessages }
        let unresolved = unresolvedUnknownCount
        if unresolved > 0 { return .unresolvedUnknown(unresolved) }
        if savableMessages().isEmpty { return .noMessages }
        return nil
    }
}

/// 确认 / 保存阶段能出现的错误：文案给人看，不吐沙盒路径、不吐聊天正文。
enum LiveChatReviewError: LocalizedError, Equatable {
    /// 没有可保存的消息（全部排除，或过滤后没有 me / other）
    case noMessages
    /// 还有 N 条保留着但角色未确定
    case unresolvedUnknown(Int)
    /// 复用 SharedChatStore 的失败原因（那边已经是用户可读文案）
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMessages:
            return "没有可保存的聊天消息。"
        case .unresolvedUnknown(let count):
            return "还有 \(count) 条消息未确定归属，先改成「我」「对方」或排除。"
        case .saveFailed(let reason):
            return reason
        }
    }
}

/// 把确认好的草稿交给**现有** SharedChatStore：校验、原子写入、错误模型全部沿用，不新建第二套通道。
struct LiveChatReviewSaver {
    let store: SharedChatStore

    /// `updatedAt` 用**本次保存时刻**，这样键盘的「30 分钟旧内容」提示语义才正确。
    func save(_ draft: LiveChatReviewDraft, updatedAt: Date = Date()) throws -> SharedChatSnapshot {
        if let error = draft.validate() { throw error }
        let payload = GoutouChatClipboardPayload(messages: draft.savableMessages())
        do {
            return try store.save(payload, updatedAt: updatedAt)
        } catch let error as SharedChatStoreError {
            throw LiveChatReviewError.saveFailed(error.localizedDescription)
        } catch {
            throw LiveChatReviewError.saveFailed("保存失败，请稍后重试。")
        }
    }
}
