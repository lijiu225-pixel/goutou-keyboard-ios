import CoreGraphics
import Foundation

/// 当前这帧屏幕看起来像不像「聊天会话界面」。
///
/// 只根据**用户主动共享的屏幕像素 + Vision 几何**判断：不看气泡颜色、不看联系人名字、
/// 不看固定分辨率，也不碰微信内部结构。
enum ChatSceneVerdict: Equatable {
    /// 证据不足（比如刚启动、整屏几乎没文字）
    case unknown
    /// 像聊天，但还没连续确认
    case candidate
    /// 连续确认：是聊天会话界面
    case activeChat
    /// 连续确认：不是聊天会话界面
    case inactive
}

extension ChatSceneVerdict {
    /// 给界面 / 灵动岛用的状态文案：只说状态，**绝不出现聊天正文**。
    var title: String {
        switch self {
        case .unknown: return "🐶 正在判断屏幕内容…"
        case .candidate: return "🐶 像是聊天界面 · 确认中…"
        case .activeChat: return "🐶 已进入聊天 · 识别中"
        case .inactive: return "🐶 未在聊天界面 · 已暂停识别"
        }
    }

    var shortTitle: String {
        switch self {
        case .unknown: return "判断中"
        case .candidate: return "确认中"
        case .activeChat: return "识别中"
        case .inactive: return "已暂停"
        }
    }
}

/// 门控的全部阈值：集中一处，方便调参也方便测试。
struct ChatSceneGateConfiguration: Equatable {
    /// 顶部导航 / 状态栏比例（聊天标题在这儿）
    var topInsetRatio: CGFloat = 0.10
    /// 底部输入栏 / 键盘比例
    var bottomInsetRatio: CGFloat = 0.28
    /// 中部消息区至少要有几条像消息的块
    var minimumMessageBlocks = 2
    /// 至少要有几块是「明显靠左或靠右」的（居中系统文字不算）
    var minimumAnchoredBlocks = 2
    /// 连续多少帧满足条件才进入 activeChat
    var requiredActiveFrames = 2
    /// 连续多少帧不满足才退出 activeChat（比进入更迟钝，避免单帧滚动/动画误退）
    var requiredInactiveFrames = 3
    /// 一条候选至少要这么宽 / 这么高才算「像消息」（滤掉噪声）
    var minimumBlockWidth: CGFloat = 0.06
    var minimumBlockHeight: CGFloat = 0.012
    /// 顶部 / 底部要有文字才算有导航栏与输入栏
    var requiredTopBarText = true
    var requiredInputBarText = true
    /// 顶部文字连续变化多少帧后认为「换了聊天会话」
    var requiredTitleChangeFrames = 2

    static let `default` = ChatSceneGateConfiguration()
}

/// 单帧证据：全部从 OCR 结果与几何算出来。
struct ChatSceneEvidence: Equatable {
    var messageBlockCount = 0
    var anchoredBlockCount = 0
    var hasTopBarText = false
    var hasInputBarText = false
    var hasCenteredText = false
    /// 顶部文字（聊天标题）的指纹，用来发现「换了个人聊天」
    var topBarFingerprint: String?
}

/// 从一帧的 observations + 候选块里收集证据（纯函数）。
enum ChatSceneDetector {

    static func evidence(
        observations: [LiveOCRObservation],
        candidates: [LiveChatCandidate],
        config: ChatSceneGateConfiguration = .default
    ) -> ChatSceneEvidence {
        var evidence = ChatSceneEvidence()

        let bottomStart = 1 - config.bottomInsetRatio
        let topText = observations
            .filter { $0.box.midY <= config.topInsetRatio && !LiveChatText.normalize($0.text).isEmpty }
            .map { $0.text.trimmed }
        evidence.hasTopBarText = !topText.isEmpty
        // 顶部文字本身就是最好的「换人聊天」信号；只做内存比较，不需要哈希
        evidence.topBarFingerprint = topText.isEmpty ? nil : topText.joined(separator: "|")

        evidence.hasInputBarText = observations.contains {
            $0.box.midY >= bottomStart && !LiveChatText.normalize($0.text).isEmpty
        }
        evidence.hasCenteredText = candidates.contains { $0.role == .system }

        let messageLike = candidates.filter {
            $0.role != .system
                && $0.box.width >= config.minimumBlockWidth
                && $0.box.height >= config.minimumBlockHeight
        }
        evidence.messageBlockCount = messageLike.count
        evidence.anchoredBlockCount = messageLike.filter { $0.role == .me || $0.role == .other }.count
        return evidence
    }

    /// 一帧像不像聊天界面：中部有若干消息块（其中至少几块能判出左右），
    /// 顶部有导航文字、底部有输入栏文字；居中系统文字只是加分项。
    static func isChatScene(_ evidence: ChatSceneEvidence, config: ChatSceneGateConfiguration = .default) -> Bool {
        guard evidence.messageBlockCount >= config.minimumMessageBlocks,
              evidence.anchoredBlockCount >= config.minimumAnchoredBlocks else { return false }
        if config.requiredTopBarText && !evidence.hasTopBarText { return false }
        if config.requiredInputBarText && !evidence.hasInputBarText { return false }
        return true
    }
}

/// 连续帧确认（hysteresis）：避免滚动、动画、键盘弹出、图片/视频/语音消息造成反复启停。
struct ChatSceneGate {
    private(set) var verdict: ChatSceneVerdict = .unknown
    private var activeStreak = 0
    private var inactiveStreak = 0
    private var observedTitle: String?
    private var titleChangeStreak = 0

    /// 返回的第二个值表示「要不要开一个新的聊天 session」——进入聊天界面、
    /// 或者确认顶部标题变了（换人聊天）时为 true。宁可新开一轮 timeline，也不混两个人的聊天。
    mutating func update(
        isChatFrame: Bool,
        titleFingerprint: String? = nil,
        config: ChatSceneGateConfiguration = .default
    ) -> (verdict: ChatSceneVerdict, startsNewSession: Bool) {
        var startsNewSession = false

        if isChatFrame {
            activeStreak += 1
            inactiveStreak = 0
        } else {
            inactiveStreak += 1
            activeStreak = 0
        }

        // 标题变化：连续几帧都不同才算「换了聊天」，避免 OCR 抖动误判
        if let titleFingerprint, let observedTitle, titleFingerprint != observedTitle {
            titleChangeStreak += 1
        } else {
            titleChangeStreak = 0
        }

        let wasActive = verdict == .activeChat
        if activeStreak >= config.requiredActiveFrames {
            verdict = .activeChat
            if !wasActive {
                startsNewSession = true          // 重新进入聊天页面：开新的一轮
            }
            if titleChangeStreak >= config.requiredTitleChangeFrames {
                startsNewSession = true          // 顶部标题变了：按「换了聊天」处理
            }
            observedTitle = titleFingerprint
            titleChangeStreak = 0
        } else if inactiveStreak >= config.requiredInactiveFrames {
            verdict = .inactive
            observedTitle = nil
            titleChangeStreak = 0
        } else if verdict != .activeChat {
            verdict = .candidate
        }
        // 已经是 activeChat、又只是零星几帧不满足：保持 activeChat（迟钝退出）
        return (verdict, startsNewSession)
    }

    mutating func reset() {
        verdict = .unknown
        activeStreak = 0
        inactiveStreak = 0
        observedTitle = nil
        titleChangeStreak = 0
    }
}
