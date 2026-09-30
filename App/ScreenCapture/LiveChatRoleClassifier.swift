import CoreGraphics
import Foundation

/// 角色判断：**只看文字块的水平几何**，不研究气泡颜色 / 头像 / 微信内部结构。
///
/// 长消息可能横跨屏幕中线，所以不能只看 centerX：这里比较左右两侧的**边距**
/// （leftGap / rightGap）判断到底是贴着哪一边。
/// 两边都贴（几乎铺满整行）或两边都不贴 → unknown：宁可判不出来，也别错误归属。
enum LiveChatRoleClassifier {

    static func classify(box: CGRect, config: LiveChatGeometryConfiguration = .default) -> LiveChatRole {
        let leftGap = box.minX
        let rightGap = 1 - box.maxX

        let leftAnchored = leftGap <= config.leftAnchorTolerance && rightGap > config.rightAnchorTolerance
        let rightAnchored = rightGap <= config.rightAnchorTolerance && leftGap > config.rightAnchorTolerance

        if rightAnchored { return .me }
        if leftAnchored { return .other }

        // 居中且足够窄（时间、撤回提示这类）才算 system；居中但很宽的内容宁可 unknown
        let centered = abs(box.midX - 0.5) <= config.centerTolerance
        if centered && box.width <= config.maxSystemWidthRatio { return .system }

        return .unknown
    }
}
