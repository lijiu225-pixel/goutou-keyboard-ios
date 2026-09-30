import SwiftUI
import WidgetKit

/// 动态识别的系统级状态入口：灵动岛 / 锁屏 Live Activity + 控制中心快捷入口。
///
/// 这个扩展**不读**聊天存储、不碰 AI、不碰 API Key：只画主 App 推过来的 `ContentState`。
@main
struct GoutouCaptureWidgetBundle: WidgetBundle {
    var body: some Widget {
        GoutouCaptureActivityWidget()
        if #available(iOS 18.0, *) {
            GoutouCaptureControl()
        }
    }
}
