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
    var topInsetRatio: CGFloat = 0.16
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

    /// Geometry from fast OCR and rectangle detection supports text-free media bubbles.
    static func probeEvidence(observations: [LiveOCRObservation], rectangles: [CGRect],
                              config: ChatSceneGateConfiguration = .default) -> ChatSceneEvidence {
        var result = evidence(observations: observations, candidates: [], config: config)
        let bottom = 1 - config.bottomInsetRatio
        let body = observations.map(\.box) + rectangles
        let anchored = body.filter {
            $0.minY > config.topInsetRatio && $0.maxY < bottom
                && $0.width >= config.minimumBlockWidth && $0.width < 0.80
                && $0.height >= config.minimumBlockHeight
                && (($0.minX < 0.20 && $0.maxX < 0.80) || ($0.maxX > 0.80 && $0.minX > 0.20))
        }
        // Count distinct vertical rows; nested rectangles must not manufacture messages.
        var rows: [CGFloat] = []
        for box in anchored where !rows.contains(where: { abs($0 - box.midY) < 0.025 }) {
            rows.append(box.midY)
        }
        result.messageBlockCount = rows.count
        result.anchoredBlockCount = rows.count
        result.hasInputBarText = observations.contains {
            $0.box.midY >= bottom && ($0.text.contains("输入") || $0.text.contains("按住") || $0.text == "发送")
        } || rectangles.contains {
            $0.midY >= bottom && $0.width > 0.35 && $0.width < 0.9 && $0.height < 0.09
        }
        let tabLabels = Set(observations.filter { $0.box.midY > 0.85 }.map { $0.text.trimmed })
        if tabLabels.intersection(["微信", "通讯录", "发现", "我"]).count >= 2 {
            result.hasInputBarText = false
        }
        return result
    }

    static func evidence(
        observations: [LiveOCRObservation],
        candidates: [LiveChatCandidate],
        config: ChatSceneGateConfiguration = .default
    ) -> ChatSceneEvidence {
        var evidence = ChatSceneEvidence()

        let bottomStart = 1 - config.bottomInsetRatio
        let title = observations.filter {
            $0.box.midY >= 0.035 && $0.box.midY <= config.topInsetRatio
                && $0.box.midX >= 0.25 && $0.box.midX <= 0.75
                && !LiveChatText.normalize($0.text).isEmpty
        }.sorted { $0.box.minY < $1.box.minY }
        evidence.hasTopBarText = !title.isEmpty
        evidence.topBarFingerprint = title.isEmpty ? nil : title.map {
            LiveChatText.normalize($0.text)
        }.joined(separator: "|")

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
    private var stableVerdict: ChatSceneVerdict = .unknown
    private var activeStreak = 0
    private var inactiveStreak = 0
    private var observedTitle: String?
    private var pendingTitle: String?
    private var titleChangeStreak = 0
    private(set) var allowsSubmission = false

    mutating func update(
        isChatFrame: Bool,
        titleFingerprint: String? = nil,
        config: ChatSceneGateConfiguration = .default
    ) -> (verdict: ChatSceneVerdict, startsNewSession: Bool) {
        allowsSubmission = false
        if !isChatFrame {
            activeStreak = 0
            inactiveStreak = min(inactiveStreak + 1, config.requiredInactiveFrames)
            titleChangeStreak = 0
            if inactiveStreak >= config.requiredInactiveFrames {
                stableVerdict = .inactive
                observedTitle = nil
            }
            verdict = stableVerdict == .unknown ? .candidate : stableVerdict
            return (verdict, false)
        }
        inactiveStreak = 0
        activeStreak = min(activeStreak + 1, config.requiredActiveFrames)
        if stableVerdict != .activeChat {
            guard activeStreak >= config.requiredActiveFrames else {
                verdict = stableVerdict == .unknown ? .candidate : stableVerdict
                return (verdict, false)
            }
            stableVerdict = .activeChat
            verdict = .activeChat
            observedTitle = titleFingerprint
            titleChangeStreak = 0
            allowsSubmission = true
            return (verdict, true)
        }
        verdict = .activeChat
        if titleFingerprint != observedTitle {
            // Do not overwrite the confirmed title on the first differing frame.
            if pendingTitle == titleFingerprint { titleChangeStreak += 1 }
            else { pendingTitle = titleFingerprint; titleChangeStreak = 1 }
            guard titleChangeStreak >= config.requiredTitleChangeFrames else {
                return (verdict, false) // Hold UI state but quarantine this frame.
            }
            observedTitle = titleFingerprint
            titleChangeStreak = 0
            allowsSubmission = true
            return (verdict, true)
        }
        titleChangeStreak = 0
        pendingTitle = nil
        allowsSubmission = true
        return (verdict, false)
    }

    mutating func reset() { self = ChatSceneGate() }
}
