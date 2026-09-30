import ActivityKit
import SwiftUI
import WidgetKit

/// 以「状态」形式展示动态识别是否在工作。
///
/// **只显示状态与计数**：条数、同步条数、未确定条数、门控与自动同步文案、最后同步时间；
/// 绝不显示任何聊天正文（隐私要求）。
struct GoutouCaptureActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GoutouCaptureActivityAttributes.self) { context in
            lockScreen(context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("狗头军师", systemImage: "pawprint.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(statusText(context.state))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.autoSyncText)
                        counts(context.state)
                        syncTime(context.state)
                    }.font(.caption2)
                }
            } compactLeading: {
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                Text(context.state.compactText)
                    .font(.caption2)
            } minimal: {
                Text(context.state.minimalText)
                    .font(.caption2).foregroundStyle(.tint)
            }
            .keylineTint(.blue)
        }
    }

    private func lockScreen(_ state: GoutouCaptureActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "pawprint.fill")
                Text("狗头军师动态识别")
                    .font(.caption)
                    .bold()
            }
            Text(statusText(state))
                .font(.caption2)
                .foregroundStyle(.secondary)
            counts(state)
                .font(.caption2)
            Text(state.autoSyncText).font(.caption2)
            syncTime(state).font(.caption2)
            if let errorText = state.errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
    }

    /// 只描述状态：识别中 / 已暂停 / 未在聊天界面…
    private func statusText(_ state: GoutouCaptureActivityAttributes.ContentState) -> String {
        state.statusText
    }

    @ViewBuilder
    private func syncTime(_ state: GoutouCaptureActivityAttributes.ContentState) -> some View {
        if let date = state.lastSyncAt {
            HStack { Text("最近同步"); Text(date, style: .time) }
        } else { Text("尚未同步") }
    }

    private func counts(_ state: GoutouCaptureActivityAttributes.ContentState) -> some View {
        HStack(spacing: 10) {
            Text("实时聊天 \(state.timelineCount) 条")
            Text("已同步 \(state.syncedCount) 条")
            Text("未确定 \(state.unknownCount) 条")
                .foregroundStyle(state.unknownCount > 0 ? .orange : .secondary)
        }
    }
}
