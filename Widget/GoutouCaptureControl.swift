import AppIntents
import SwiftUI
import WidgetKit

/// 控制中心的「打开狗头军师」快捷入口。
///
/// 它**只**做一件事：把 App 打开（由系统决定前台）。它**不会**、也无法绕过系统内容共享界面
/// 去偷偷开始整屏捕获，更不会把「自动同步」变成持久授权——12D 的授权语义不变。
@available(iOS 18.0, *)
struct OpenGoutouCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "打开狗头军师动态识别"
    /// 系统允许的语义：运行这个 Intent 会把 App 带到前台，由用户自己决定下一步。
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

@available(iOS 18.0, *)
struct GoutouCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.example.goutouinput.capture") {
            ControlWidgetButton(action: OpenGoutouCaptureIntent()) {
                Label("狗头军师", systemImage: "pawprint.fill")
            }
        }
        .displayName("狗头军师")
        .description("打开动态识别页面（不会绕过系统整屏共享授权）。")
    }
}
