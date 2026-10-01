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
///
/// 判定以**结构**为主：顶部导航带 + 底部输入区 + 中部消息块几何 + 左右锚点。
/// 不要求标题是「居中的纯文字」，也不要求识别到多少条正文——图片 / 视频 / 语音为主的
/// 聊天页面同样要能判出来。
struct ChatSceneGateConfiguration: Equatable {
    /// 顶部导航带（聊天标题 / 头像 / 在线状态都在这一带）
    var navigationBandStart: CGFloat = 0.030
    var navigationBandEnd: CGFloat = 0.17
    /// 中部消息带的上边界
    var bodyTopRatio: CGFloat = 0.17
    /// 没有找到输入栏时，消息带的下边界
    var bodyBottomRatio: CGFloat = 0.72
    /// 底部输入区：至少从这个高度往下找
    var inputBandStart: CGFloat = 0.45
    var minimumInputHeight: CGFloat = 0.012
    var maximumInputHeight: CGFloat = 0.09
    /// 输入框比气泡宽得多：低于这个宽度的扁平矩形按消息气泡处理，不算输入栏
    var minimumInputWidth: CGFloat = 0.40
    var maximumInputWidth: CGFloat = 0.94
    /// 一条消息块至少要这么宽 / 这么高才算「像消息」（滤掉噪声）
    var minimumBlockWidth: CGFloat = 0.06
    var minimumBlockHeight: CGFloat = 0.012
    /// 一块消息最多这么宽（整屏通栏的行更像列表 / 正文，不是气泡）
    var maximumBlockWidth: CGFloat = 0.94
    /// 右锚定气泡至少要这么宽：把右侧的图标列 / 时间戳排除掉
    var minimumRightBlockWidth: CGFloat = 0.18
    /// 左右锚点的分界（用中点判断，长消息跨中线也能归边）
    var leftAnchorMidX: CGFloat = 0.48
    var rightAnchorMidX: CGFloat = 0.52
    /// 居中系统文字（日期 / 撤回提示）的宽度上限
    var maximumCenteredWidth: CGFloat = 0.30
    /// 中部消息区至少要有几条「像消息」的行
    var minimumMessageBlocks = 2
    /// 没有输入栏可用时，退化成「左右都有气泡」需要几条行
    var minimumTwoSidedBlocks = 3
    /// 微信底部 tab（微信 / 通讯录 / 发现 / 我）出现几个以上就判定成列表首页
    var tabBarDisqualifyCount = 2
    /// 连续多少帧满足条件才进入 activeChat
    var requiredActiveFrames = 2
    /// 连续多少帧不满足才退出 activeChat（比进入更迟钝，避免单帧滚动/动画误退）
    var requiredInactiveFrames = 3
    /// 顶部文字连续变化多少帧后认为「换了聊天会话」
    var requiredTitleChangeFrames = 2
    /// Unconfirmed OCR stays bounded in memory, never in the shared store.
    var maximumPendingFrames = 8
    var maximumPendingObservations = 200
    var maximumPendingCharacters = 16_384

    static let `default` = ChatSceneGateConfiguration()
}

/// 单帧证据：全部从 OCR 结果与几何算出来。**只有结构与计数，不含任何聊天正文。**
struct ChatSceneEvidence: Equatable {
    /// 中部消息带里「像消息」的行数
    var messageRowCount = 0
    /// 偏左 / 偏右 / 居中的块数（诊断与左右锚点用）
    var leftMessageCount = 0
    var rightMessageCount = 0
    var centeredMessageCount = 0
    /// 顶部导航带里的文字行数（标题 / 头像旁的名字 / 在线状态）
    var navigationLineCount = 0
    var hasInputBar = false
    /// 微信底部 tab 命中数：≥2 就是列表首页，不是聊天
    var tabBarLineCount = 0
    /// 顶部文字（聊天标题）的指纹，用来发现「换了个人聊天」
    var topBarFingerprint: String?
    /// 输入区上边界（比例），用于收紧消息带
    var inputTopRatio: CGFloat?
    /// 诊断用的综合置信度 0～1
    var confidence: CGFloat = 0
    var hasNonChatNavigation = false

    var hasNavigationBar: Bool { navigationLineCount > 0 }

    /// 诊断文案：只说结构，**绝不出现聊天正文**。
    var diagnostics: String {
        var parts = [
            "confidence=\(String(format: "%.2f", Double(confidence)))",
            "nav=\(hasNavigationBar ? "yes" : "no")(\(navigationLineCount))",
            "input=\(hasInputBar ? "yes" : "no")",
            "rows=\(messageRowCount)",
            "left=\(leftMessageCount)",
            "right=\(rightMessageCount)",
            "center=\(centeredMessageCount)",
            "tab=\(tabBarLineCount)",
        ]
        if let inputTopRatio { parts.append("inputTop=\(String(format: "%.2f", Double(inputTopRatio)))") }
        return parts.joined(separator: " ")
    }
}

/// 从一帧的 observations + 候选块里收集证据（纯函数）。
enum ChatSceneDetector {

    /// 快速 OCR + 矩形几何：图片 / 视频 / 语音为主、几乎没有正文的聊天页也能判出来。
    static func probeEvidence(observations: [LiveOCRObservation], rectangles: [CGRect],
                              config: ChatSceneGateConfiguration = .default) -> ChatSceneEvidence {
        analyze(observations: observations, candidates: [], rectangles: rectangles, config: config)
    }

    /// 已经有候选块时走这里（老链路：只有 observations + candidates，没有矩形）。
    static func evidence(
        observations: [LiveOCRObservation],
        candidates: [LiveChatCandidate],
        config: ChatSceneGateConfiguration = .default
    ) -> ChatSceneEvidence {
        analyze(observations: observations, candidates: candidates, rectangles: [], config: config)
    }

    static func analyze(
        observations: [LiveOCRObservation],
        candidates: [LiveChatCandidate],
        rectangles: [CGRect],
        config: ChatSceneGateConfiguration = .default
    ) -> ChatSceneEvidence {
        var evidence = ChatSceneEvidence()

        // 顶部导航带：**不要求居中、不要求纯文字**。带返回箭头 + 头像 + 名字 + 在线状态的
        // 微信导航栏一样要能认出来，所以只看「这一带有没有文字」。
        let navigation = observations.filter {
            $0.box.midY >= config.navigationBandStart && $0.box.midY <= config.navigationBandEnd
                && !LiveChatText.normalize($0.text).isEmpty
        }.sorted { $0.box.minY < $1.box.minY }
        evidence.navigationLineCount = navigation.count
        let navigationLabels = Set(navigation.map { $0.text.trimmed })
        evidence.hasNonChatNavigation = !navigationLabels.intersection(["朋友圈", "设置", "桌面", "联系人列表", "微信首页", "短视频"]).isEmpty
            || navigationLabels.isSuperset(of: ["关注", "推荐"])
        evidence.topBarFingerprint = navigation.isEmpty ? nil : navigation.map {
            LiveChatText.normalize($0.text)
        }.joined(separator: "|")

        // 底部输入区：占位文字，或者「宽而扁」的输入框几何。两个都没有才算没有输入区。
        let placeholder = observations.filter {
            $0.box.minY >= config.inputBandStart
                && ($0.text.contains("输入") || $0.text.contains("按住") || $0.text == "发送")
        }.map(\.box)
        let inputBoxes = rectangles.filter {
            $0.minY >= config.inputBandStart
                && $0.width >= config.minimumInputWidth && $0.width <= config.maximumInputWidth
                && $0.height >= config.minimumInputHeight && $0.height <= config.maximumInputHeight
                && $0.minX >= 0.02 && $0.maxX <= 0.98
        }
        evidence.inputTopRatio = (placeholder + inputBoxes).map(\.minY).min()
        evidence.hasInputBar = evidence.inputTopRatio != nil

        // 微信底部 tab 命中：联系人列表 / 首页这类分栏页面直接判非聊天
        let tabLabels = observations.filter { $0.box.midY > 0.86 }.map { $0.text.trimmed }
        evidence.tabBarLineCount = Set(tabLabels).intersection(["微信", "通讯录", "发现", "我"]).count

        // 中部消息带：输入区以上、导航带以下。输入区没找到时用默认下边界。
        let inputTop = evidence.inputTopRatio ?? config.bodyBottomRatio
        let bodyLowerBound = min(max(inputTop, config.bodyTopRatio), 1)
        let candidateBoxes = candidates.filter { $0.role != .system }.map(\.box)
        let body = observations.map(\.box) + candidateBoxes + rectangles
        var rows: [CGFloat] = []
        for box in body {
            guard box.minY >= config.bodyTopRatio, box.maxY <= bodyLowerBound,
                  box.width >= config.minimumBlockWidth, box.width <= config.maximumBlockWidth,
                  box.height >= config.minimumBlockHeight else { continue }
            // 一个矩形套着一个文字框时不能算两条消息：同一纵向位置只记一次
            if !rows.contains(where: { abs($0 - box.midY) < 0.025 }) { rows.append(box.midY) }
            if box.midX <= config.leftAnchorMidX {
                evidence.leftMessageCount += 1
            } else if box.midX >= config.rightAnchorMidX, box.width >= config.minimumRightBlockWidth {
                evidence.rightMessageCount += 1
            } else if abs(box.midX - 0.5) <= 0.06, box.width <= config.maximumCenteredWidth {
                evidence.centeredMessageCount += 1
            }
        }
        evidence.messageRowCount = rows.count
        evidence.confidence = confidence(evidence, config: config)
        return evidence
    }

    /// 一帧像不像聊天界面。
    ///
    /// 两个入口，任意一个成立即算聊天：
    /// ① **输入栏 + 消息**：底部有聊天输入区，且顶部有导航文字或中部有消息行；
    /// ② **左右都有气泡**：中部同时存在明显偏左和明显偏右的气泡行（列表 / 信息流做不到），
    ///    即使输入栏这次没被检测出来也仍然算聊天。
    /// 微信底部 tab 命中两个以上的一律判非聊天。
    static func isChatScene(_ evidence: ChatSceneEvidence, config: ChatSceneGateConfiguration = .default) -> Bool {
        guard evidence.tabBarLineCount < config.tabBarDisqualifyCount else { return false }
        guard evidence.messageRowCount >= 1 else { return false }
        let inputBacked = evidence.hasInputBar
            && (evidence.hasNavigationBar || evidence.messageRowCount >= config.minimumMessageBlocks)
        let bubbleBacked = evidence.leftMessageCount > 0
            && evidence.rightMessageCount > 0
            && evidence.messageRowCount >= config.minimumTwoSidedBlocks
        return inputBacked || bubbleBacked
    }

    /// Missing input/title/message evidence is uncertainty, not an exit signal.
    static func isClearlyNonChatScene(_ evidence: ChatSceneEvidence, config: ChatSceneGateConfiguration = .default) -> Bool {
        if evidence.tabBarLineCount >= config.tabBarDisqualifyCount { return true }
        guard !isChatScene(evidence, config: config), !evidence.hasInputBar else { return false }
        return evidence.hasNonChatNavigation
    }

    /// 诊断用的综合置信度：只做展示与调参参考，判定本身走 `isChatScene`。
    static func confidence(_ evidence: ChatSceneEvidence, config: ChatSceneGateConfiguration = .default) -> CGFloat {
        guard evidence.tabBarLineCount < config.tabBarDisqualifyCount else { return 0 }
        var score: CGFloat = 0
        if evidence.hasNavigationBar { score += 0.25 }
        if evidence.hasInputBar { score += 0.30 }
        score += min(CGFloat(evidence.messageRowCount), 3) / 3 * 0.30
        if evidence.leftMessageCount > 0 && evidence.rightMessageCount > 0 { score += 0.10 }
        if evidence.centeredMessageCount > 0 { score += 0.05 }
        return min(score, 1)
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
    private var needsNewSessionOnResume = false
    private(set) var allowsSubmission = false

    /// 诊断用：连续满足 / 连续不满足的帧数（Release 不打印任何东西）。
    var enterStreak: Int { activeStreak }
    var exitStreak: Int { inactiveStreak }
    var hasConfirmedTitle: Bool { observedTitle != nil }

    mutating func update(
        isChatFrame: Bool,
        titleFingerprint: String? = nil,
        isClearlyNonChatFrame: Bool = true,
        config: ChatSceneGateConfiguration = .default
    ) -> (verdict: ChatSceneVerdict, startsNewSession: Bool) {
        allowsSubmission = false
        if !isChatFrame {
            if !isClearlyNonChatFrame {
                activeStreak = 0
                inactiveStreak = 0
                titleChangeStreak = 0
                pendingTitle = nil
                verdict = stableVerdict
                return (verdict, false)
            }
            if stableVerdict == .activeChat { needsNewSessionOnResume = true }
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
            needsNewSessionOnResume = false
            titleChangeStreak = 0
            allowsSubmission = titleFingerprint != nil
            return (verdict, true)
        }
        verdict = .activeChat
        if needsNewSessionOnResume {
            guard activeStreak >= config.requiredActiveFrames else { return (verdict, false) }
            needsNewSessionOnResume = false
            observedTitle = titleFingerprint
            titleChangeStreak = 0
            allowsSubmission = titleFingerprint != nil
            return (verdict, true)
        }
        if titleFingerprint != observedTitle {
            // Missing title preserves display/OCR but never authorizes timeline submission.
            if let titleFingerprint {
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
        }
        titleChangeStreak = 0
        pendingTitle = nil
        allowsSubmission = titleFingerprint != nil
        return (verdict, false)
    }

    mutating func reset() { self = ChatSceneGate() }
}
