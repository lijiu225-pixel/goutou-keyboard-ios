import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// 把规划器的动作真正落到 ActivityKit 上（灵动岛 / 锁屏 Live Activity）。
///
/// 只在主线程调用。**任何 ActivityKit 失败都只记一句原因**，绝不影响捕获、OCR、时间线、
/// 自动同步、共享聊天或键盘——它只是状态显示。
final class GoutouCaptureActivityController {

    private var planner = GoutouCaptureActivityPlanner()
    /// 用 AnyObject 存，让不支持 ActivityKit 的 SDK 也能编译（和 ScreenCaptureKit 同一套做法）
    private var activity: AnyObject?
    /// 上一次 ActivityKit 失败的简短原因（界面上只用来提示「状态没起来」）
    private(set) var lastError: String?

    var isRunning: Bool { planner.isRunning }

    func captureStarted(sessionID: String, content: GoutouCaptureActivityContent, now: Date = Date()) {
        apply(planner.captureStarted(sessionID: sessionID, content: content, now: now))
    }

    func stateChanged(_ content: GoutouCaptureActivityContent, now: Date = Date()) {
        apply(planner.stateChanged(content, now: now))
    }

    func captureStopped(_ content: GoutouCaptureActivityContent, now: Date = Date()) {
        apply(planner.captureStopped(content, now: now))
    }

    // MARK: - ActivityKit

    private func apply(_ action: GoutouCaptureActivityAction) {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            switch action {
            case .none:
                break

            case .start(let content):
                // 先收掉可能残留的旧 Activity，避免累积多个狗头军师状态
                for stale in Activity<GoutouCaptureActivityAttributes>.activities {
                    Task { await stale.end(nil, dismissalPolicy: .immediate) }
                }
                do {
                    let attributes = GoutouCaptureActivityAttributes(
                        sessionID: planner.sessionID ?? UUID().uuidString
                    )
                    activity = try Activity.request(
                        attributes: attributes,
                        content: ActivityContent(state: Self.state(from: content), staleDate: nil)
                    )
                    lastError = nil
                } catch {
                    // 灵动岛起不来不是致命问题：识别与共享照常
                    lastError = "灵动岛状态没能启动（识别不受影响）"
                }

            case .update(let content):
                guard let current = activity as? Activity<GoutouCaptureActivityAttributes> else { break }
                Task { await current.update(ActivityContent(state: Self.state(from: content), staleDate: nil)) }

            case .end(let content):
                guard let current = activity as? Activity<GoutouCaptureActivityAttributes> else { break }
                activity = nil
                Task {
                    await current.end(
                        ActivityContent(state: Self.state(from: content), staleDate: nil),
                        dismissalPolicy: .immediate
                    )
                }
            }
            return
        }
        #endif
        // 系统不支持 Live Activity（或 SDK 里没有 ActivityKit）：什么都不做，其余功能照常
    }

    #if canImport(ActivityKit)
    @available(iOS 16.2, *)
    private static func state(
        from content: GoutouCaptureActivityContent
    ) -> GoutouCaptureActivityAttributes.ContentState {
        GoutouCaptureActivityAttributes.ContentState(
            capturing: content.capturing,
            gateText: content.gateText,
            autoSyncText: content.autoSyncText,
            timelineCount: content.timelineCount,
            syncedCount: content.syncedCount,
            unknownCount: content.unknownCount,
            lastSyncAt: content.lastSyncAt,
            errorText: content.errorText
        )
    }
    #endif
}
