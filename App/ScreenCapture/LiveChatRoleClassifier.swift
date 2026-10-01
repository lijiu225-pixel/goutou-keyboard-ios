import CoreGraphics
import Foundation

/// 优先使用经过扫描校验的气泡边缘和底色；没有像素证据时保留文字几何判断。
///
/// 长消息可能横跨屏幕中线，所以不能只看 centerX：这里比较左右两侧的**边距**
/// （leftGap / rightGap）判断到底是贴着哪一边。
/// 两边都贴（几乎铺满整行）或两边都不贴 → unknown：宁可判不出来，也别错误归属。
enum LiveChatRoleClassifier {

    static func classify(_ observation: LiveOCRObservation,
                         config: LiveChatGeometryConfiguration = .default) -> LiveChatRole {
        guard let bubble = observation.bubble,
              bubble.minX.isFinite, bubble.maxX.isFinite,
              bubble.minX >= 0, bubble.maxX <= 1, bubble.maxX - bubble.minX >= 0.03,
              bubble.minX <= observation.box.minX + 0.012,
              bubble.maxX >= observation.box.maxX - 0.012 else {
            return classify(box: observation.box, config: config)
        }
        let span = CGRect(x: bubble.minX, y: observation.box.minY,
                          width: bubble.maxX - bubble.minX, height: observation.box.height)
        let geometry = classify(box: span, config: config)
        let avatar: LiveChatRole?
        switch bubble.avatarSide {
        case .left: avatar = .other
        case .right: avatar = .me
        case .none: avatar = nil
        }
        // Verified cues may disagree (media or a custom theme): hold for review.
        if let avatar = avatar, (geometry == .me || geometry == .other), avatar != geometry { return .unknown }
        if bubble.isGreen {
            if geometry == .other || avatar == .other { return .unknown }
            return .me
        }
        if let avatar = avatar { return avatar }
        return geometry == .me || geometry == .other ? geometry : .unknown
    }

    static func classify(block: [LiveOCRObservation], box: CGRect,
                         config: LiveChatGeometryConfiguration = .default) -> LiveChatRole {
        guard block.contains(where: { $0.bubble != nil }) else { return classify(box: box, config: config) }
        if block.contains(where: {
            guard let bubble = $0.bubble else { return false }
            return (bubble.isGreen || bubble.avatarSide != .none) && classify($0, config: config) == .unknown
        }) { return .unknown }
        let roles = block.map { classify($0, config: config) }.filter { $0 == .me || $0 == .other }
        guard let first = roles.first, roles.allSatisfy({ $0 == first }) else { return .unknown }
        return first
    }

    /// Require centered placement AND a whole system label. Mentioning a date in
    /// a speaker's bubble must not remove that message from the conversation.
    static func isSystemLabel(text: String, box: CGRect,
                              config: LiveChatGeometryConfiguration = .default) -> Bool {
        guard abs(box.midX - 0.5) <= config.centerTolerance else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let clock = "(?:[01]?[0-9]|2[0-3])[:：][0-5][0-9]"
        let date = "(?:(?:[0-9]{4}年)?[0-9]{1,2}月[0-9]{1,2}日|[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2}|今天|昨天|前天|星期[一二三四五六日天]|周[一二三四五六日天])"
        let patterns = [
            "^" + clock + "$",
            "^" + date + "(?:\\s*(?:星期|周)[一二三四五六日天])?(?:\\s*(?:上午|下午|晚上|凌晨)?\\s*" + clock + ")?$",
            "^.+撤回了一条消息(?:[，,。]?\\s*重新编辑)?$",
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }

    static func classify(box: CGRect, config: LiveChatGeometryConfiguration = .default) -> LiveChatRole {
        let leftGap = box.minX
        let rightGap = 1 - box.maxX

        let leftAnchored = leftGap <= config.leftAnchorTolerance
            && (rightGap > config.rightAnchorTolerance || rightGap - leftGap > config.centerTolerance)
        let rightAnchored = rightGap <= config.rightAnchorTolerance
            && (leftGap > config.leftAnchorTolerance || leftGap - rightGap > config.centerTolerance)

        if rightAnchored { return .me }
        if leftAnchored { return .other }

        // 居中且足够窄（时间、撤回提示这类）才算 system；居中但很宽的内容宁可 unknown
        let centered = abs(box.midX - 0.5) <= config.centerTolerance
        if centered && box.width <= config.maxSystemWidthRatio { return .system }

        return .unknown
    }
}
