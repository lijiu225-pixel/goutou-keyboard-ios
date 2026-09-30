#if canImport(ActivityKit)
import ActivityKit
#endif
import Foundation

/// 灵动岛 / 锁屏 Live Activity 的**静态属性**：主 App 与 Widget 扩展编译同一份定义（不复制两份）。
///
/// 只放一个会话标识；真正的动态内容在 `ContentState`。
@available(iOS 16.1, *)
struct GoutouCaptureActivityAttributes: ActivityAttributes {

    /// 动态内容：**只有状态与计数，绝不含任何聊天正文**。
    struct ContentState: Codable, Hashable {
        /// 是否正在捕获
        var capturing: Bool
        /// 门控状态文案（识别中 / 已暂停识别…）
        var gateText: String
        /// 自动同步状态文案
        var autoSyncText: String
        /// 实时聊天条数
        var timelineCount: Int
        /// 最后一次成功同步的条数
        var syncedCount: Int
        /// 未确定归属的条数
        var unknownCount: Int
        /// 最后一次成功同步时间
        var lastSyncAt: Date?
        /// 出错时的简短原因（不含正文 / 路径）
        var errorText: String?
        /// 锁屏 / expanded 的一行状态
        var statusText: String
        /// compact 右侧：条数或很短的暂停 / 停止状态
        var compactText: String
        /// minimal 更窄，只给数字或短符号
        var minimalText: String
    }

    /// 一轮 capture session 的标识：换了 session 就是新的 Activity
    var sessionID: String
}
