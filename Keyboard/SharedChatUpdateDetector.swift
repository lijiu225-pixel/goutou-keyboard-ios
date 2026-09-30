import Foundation

/// 键盘发现的一份「用户还没采用」的共享聊天。
///
/// 只是内存里的待处理状态：不写偏好设置、不新增 App Group 文件、不落盘。
struct PendingSharedChatUpdate: Equatable {
    let snapshot: SharedChatSnapshot
    let fingerprint: String

    var messageCount: Int { snapshot.messages.count }
    var updatedAt: Date { snapshot.updatedAt }
}

/// 键盘侧「共享聊天有没有更新」的独立状态：**不和 AI 分析状态混在一起**。
enum SharedChatUpdateState: Equatable {
    /// 没开始检查 / 没有可比的对象
    case idle
    case checking
    /// 当前上下文已经就是最新那份
    case upToDate
    /// 有一份更新的共享聊天等着用户决定
    case available(PendingSharedChatUpdate)
    /// 自动检查失败：只记原因，**不摧毁**当前上下文、分析与回复
    case failedNonDestructive(String)

    var pending: PendingSharedChatUpdate? {
        if case .available(let update) = self { return update }
        return nil
    }
}

/// 比较「键盘已经知道的那份聊天」和 SharedChatStore 里的最新内容。
///
/// 纯逻辑、无 I/O：文件读取由控制器负责，这里只做判定，方便单测。
enum SharedChatUpdateDetector {

    static func fingerprint(of snapshot: SharedChatSnapshot) -> String {
        SharedChatFingerprint.make(messages: snapshot.messages)
    }

    /// `knownFingerprint` = 键盘当前已经**预览过或使用过**的聊天指纹（nil = 这次 session 还没拿到过）。
    ///
    /// 只靠 `updatedAt` 会漏：同一分钟写两次、时间元数据异常都判断不出来，所以一律用内容指纹比。
    static func evaluate(shared: SharedChatSnapshot, knownFingerprint: String?) -> SharedChatUpdateState {
        guard !shared.messages.isEmpty else { return .upToDate }
        let fingerprint = fingerprint(of: shared)
        guard fingerprint != knownFingerprint else { return .upToDate }
        return .available(PendingSharedChatUpdate(snapshot: shared, fingerprint: fingerprint))
    }
}
