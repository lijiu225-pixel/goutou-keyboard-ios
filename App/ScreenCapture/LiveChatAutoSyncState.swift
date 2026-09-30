import Foundation

/// 自动同步的状态：一个状态一个值，UI 直接照着显示，不用一堆互相矛盾的 Bool。
enum LiveChatAutoSyncState: Equatable {
    /// 默认就是它：用户没主动开启
    case disabled
    /// 开着，但当前还没有能同步的 me / other
    case waitingForChat
    /// 有 N 条归属未确定：整次自动同步暂停，旧聊天保持不动
    case blockedUnknown(count: Int)
    /// 已经排上队，等聊天稳定下来再写（debounce 中）
    case scheduled
    /// 正在写
    case syncing
    case synced(messageCount: Int, at: Date)
    case failed(String)
    /// 用户刚用人工确认（阶段 12C）保存过：自动同步暂停，必须用户再次明确开启才能恢复
    case pausedAfterManualSave

    var title: String {
        switch self {
        case .disabled: return "已关闭"
        case .waitingForChat: return "等待聊天"
        case .blockedUnknown(let count): return "有 \(count) 条消息归属未确定，自动同步已暂停"
        case .scheduled: return "等待稳定…"
        case .syncing: return "正在同步…"
        case .synced(let count, _): return "已同步 \(count) 条"
        case .failed(let reason): return "同步失败：\(reason)"
        case .pausedAfterManualSave: return "已按人工确认结果保存，自动同步已暂停"
        }
    }
}

/// 一次自动同步用的**冻结**快照：只有 me / other，顺序不变，正文用当前时间线的文本。
///
/// 时间线在 debounce 期间继续变化不会影响它——旧的那份会被取消，然后按新快照重新计时。
struct LiveChatAutoSyncSnapshot: Equatable {
    let messages: [GoutouChatClipboardMessage]
    let fingerprint: String
    let generation: Int

    var count: Int { messages.count }
}

/// 从时间线造正式 payload 的结果。
enum LiveChatAutoSyncBuildResult: Equatable {
    case blockedUnknown(count: Int)
    case waitingForChat
    case ready(LiveChatAutoSyncSnapshot)
}

/// 一次自动同步写盘失败的原因：一句话，给人看，不吐沙盒路径、不吐聊天正文。
struct LiveChatAutoSyncFailure: Error, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// 指纹：deterministic 的 SHA-256（**不用** Swift 默认 Hasher —— 它带随机 seed，跨运行不稳定）。
///
/// 只用于内存里比较「内容是否真的变了」，绝不写进正式 JSON。
enum LiveChatAutoSyncFingerprint {
    /// 和键盘侧（阶段 12E）共用同一套算法：两端对「是不是同一份聊天」的判断必须一致。
    static func make(messages: [GoutouChatClipboardMessage], version: String) -> String {
        SharedChatFingerprint.make(messages: messages, version: version)
    }
}

/// 时间线 → 正式 payload：system 丢弃、unknown 直接拦下、其余按原顺序。
enum LiveChatAutoSyncPayloadBuilder {
    static func build(
        from candidates: [LiveChatCandidate],
        generation: Int,
        config: LiveChatAutoSyncConfiguration = .default
    ) -> LiveChatAutoSyncBuildResult {
        // unknown 必须整次拦住：既不猜成某一方，也不偷偷丢掉以后继续保存
        let unknown = candidates.filter { $0.role == .unknown }.count
        if unknown > 0 { return .blockedUnknown(count: unknown) }

        var messages: [GoutouChatClipboardMessage] = []
        for candidate in candidates {
            // system（时间 / 撤回提示 / 居中系统文字）永远不进正式 payload
            guard candidate.role != .system else { continue }
            guard let role = GoutouChatRole(rawValue: candidate.role.rawValue) else { continue }
            let text = candidate.text.trimmed
            guard !text.isEmpty else { continue }
            messages.append(GoutouChatClipboardMessage(role: role, text: text))
        }
        guard !messages.isEmpty else { return .waitingForChat }

        return .ready(LiveChatAutoSyncSnapshot(
            messages: messages,
            fingerprint: LiveChatAutoSyncFingerprint.make(messages: messages, version: config.fingerprintVersion),
            generation: generation
        ))
    }
}
