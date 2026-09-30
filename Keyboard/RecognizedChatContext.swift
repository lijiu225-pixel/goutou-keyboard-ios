import Foundation

/// 键盘**当前正在使用**的识别聊天临时上下文。
///
/// 只活在键盘进程的内存里：不写 UserDefaults、不写 App Group 新文件、不进 Keychain、
/// 不进人物档案和人物记忆。键盘被系统回收后重新「读取识别聊天 → 使用这份聊天」即可重建。
///
/// 消息保持结构化（`role` + `text`），本阶段**不**拼 Prompt、**不**碰 AI；
/// Prompt 怎么构造留给阶段 9。
struct RecognizedChatContext: Equatable {
    let messages: [GoutouChatClipboardMessage]
    let updatedAt: Date

    var messageCount: Int { messages.count }
}

/// 面板要能一眼分开的三态：还没读 / 读到了但没用 / 正在用。
enum RecognizedChatStatus: Equatable {
    case notLoaded
    case previewing(messageCount: Int)
    case inUse(messageCount: Int)
}

/// 预览 → 使用 → 取消使用 → 重新读取 → 读取失败 的状态机。
///
/// 纯值类型，自己不持有任何文件或网络依赖：读取动作由调用方以闭包注入。
/// 这样「读取失败绝不能留下旧的活动上下文」这类规则可以脱离键盘单独跑测试，
/// UI 只负责显示 `status` 和触发 `read` / `usePreview` / `cancelUse`。
struct RecognizedChatSession: Equatable {
    private(set) var preview: SharedChatSnapshot?
    private(set) var errorMessage: String?
    private(set) var active: RecognizedChatContext?

    /// 生产代码从空状态开始；测试可以直接铺一个初始状态。
    init(preview: SharedChatSnapshot? = nil, errorMessage: String? = nil, active: RecognizedChatContext? = nil) {
        self.preview = preview
        self.errorMessage = errorMessage
        self.active = active
    }

    var status: RecognizedChatStatus {
        if let active = active { return .inUse(messageCount: active.messageCount) }
        if let preview = preview { return .previewing(messageCount: preview.messages.count) }
        return .notLoaded
    }

    /// 「使用这份聊天」现在能不能点：预览有效且非空，而且还没有正在使用的一份。
    /// 取消使用之后又能点——看到预览 ≠ 正在使用。
    var canUsePreview: Bool {
        guard active == nil, let preview = preview else { return false }
        return !preview.messages.isEmpty
    }

    /// 重新读取：**先**作废旧预览和旧的活动上下文，再做文件 I/O。
    ///
    /// 这样「上一次用着聊天 A，这一次读聊天 B 失败」不会让 A 在后台继续当上下文。
    mutating func read(_ load: () throws -> SharedChatSnapshot) {
        reset()
        do {
            let snapshot = try load()
            // SharedChatStore 已经拒绝空消息，这里再兜一层：空聊天永远进不了预览。
            guard !snapshot.messages.isEmpty else {
                errorMessage = "聊天消息为空，不能预览或使用。"
                return
            }
            preview = snapshot
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 连读取都发起不了（例如没开键盘「允许完全访问」）：同样先作废旧状态。
    mutating func invalidate(withError message: String) {
        reset()
        errorMessage = message
    }

    /// 把当前预览复制成活动上下文。
    ///
    /// 只改内存状态：不读文件、不写持久化、不发任何网络请求。
    @discardableResult
    mutating func usePreview() -> Bool {
        guard let preview = preview, !preview.messages.isEmpty else { return false }
        active = RecognizedChatContext(messages: preview.messages, updatedAt: preview.updatedAt)
        return true
    }

    /// 只清活动上下文；预览和共享文件都不动。取消使用 ≠ 删除共享聊天。
    mutating func cancelUse() {
        active = nil
    }

    private mutating func reset() {
        preview = nil
        errorMessage = nil
        active = nil
    }
}
