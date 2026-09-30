import CoreGraphics
import Foundation

/// 阶段 12B 的全部几何阈值：集中一处，方便调参、也方便测试。
///
/// 不同机型（刘海 / 灵动岛 / 键盘高度）比例不一样，所以这些值必须可配置，
/// 不能散落到多个文件里写成 magic number。给的是竖屏微信的合理默认值。
struct LiveChatGeometryConfiguration: Equatable {
    /// 顶部状态栏 + 聊天标题占屏幕高度的比例：这一带不进聊天
    var topInsetRatio: CGFloat = 0.10
    /// 底部输入栏 + 键盘占屏幕高度的比例：这一带不进聊天
    var bottomInsetRatio: CGFloat = 0.28

    /// 离左边多近算「明显左对齐」。
    /// 取 0.12 而不是更小：微信里对方气泡左边要留头像，气泡左边缘通常在 0.10 左右；
    /// 「我」的气泡同理离右边约 0.10（右边是头像）。再小就会把真实气泡判成 unknown。
    var leftAnchorTolerance: CGFloat = 0.12
    /// 离右边多近算「明显右对齐」
    var rightAnchorTolerance: CGFloat = 0.12
    /// |centerX - 0.5| 小于它算「居中」
    var centerTolerance: CGFloat = 0.06
    /// 居中文字还得窄于这个宽度才算 system（时间 / 撤回提示）；更宽的居中内容宁可 unknown
    var maxSystemWidthRatio: CGFloat = 0.25

    /// 两行垂直间距小于它才可能属于同一条消息。
    /// 比「两个独立气泡之间的空隙」更紧：微信里同一条消息的行距通常更小，
    /// 不然连续两条「哈哈」会被粘成一条。
    var lineMergeDistance: CGFloat = 0.008
    /// 两行水平重叠比例达到它才认为同属一条消息
    var lineMergeOverlapRatio: CGFloat = 0.35
    /// 行高比例超过它就不合并（字号差太多）
    var lineHeightTolerance: CGFloat = 1.8

    /// 同一候选要**连续**出现在多少个有效 OCR 帧里才算稳定
    var requiredStableObservations: Int = 2
    /// 文本相似度达到它就当作同一条（OCR 抖动容错）
    var similarityThreshold: Double = 0.86
    /// 找 overlap 时最多看窗口内多少条（性能保护）
    var overlapSearchWindow: Int = 40
    /// overlap 至少要连续匹配几条才算可靠（宁可判不连续，也别硬拼）
    var minimumOverlapLength: Int = 2
    /// 时间线最多保留多少条：和剪贴板契约的 200 条一致，超出丢最早的
    var maxTimelineMessages: Int = GoutouChatClipboardCodec.maxMessages

    static let `default` = LiveChatGeometryConfiguration()
}
