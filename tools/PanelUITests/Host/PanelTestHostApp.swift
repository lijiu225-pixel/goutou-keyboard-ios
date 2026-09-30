import SwiftUI

/// 面板回归的宿主 App：**只为跑单元测试存在**，不参与发布。
///
/// 用 SwiftUI App 是因为 iOS 27 SDK 拒绝启动「非 UIScene 生命周期」的 App
/// （Application failed to launch: UIScene life cycle is required for apps built with this SDK），
/// 而 SwiftUI App 天然就是 scene-based。测试自己建窗口，不依赖这个宿主画什么。
@main
struct PanelTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
    }
}
