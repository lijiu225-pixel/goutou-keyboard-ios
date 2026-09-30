import SwiftUI

/// 阶段 12A 的独立测试页：只证明「用户主动授权整屏 → 主 App 在后台仍能收到屏幕帧 →
/// 本机 Vision 能识别出画面文字」。不做聊天结构、不做我/对方、不联网、不调用 AI。
struct LiveScreenCaptureView: View {

    @StateObject private var manager = LiveScreenCaptureManager()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        Form {
            Section {
                LabeledContent("状态", value: manager.model.state.title)
                Button("开始动态识别测试") { manager.start() }
                    .disabled(!manager.model.state.canStart)
                Button("停止动态识别", role: .destructive) { manager.stop() }
                    .disabled(!manager.model.state.canStop)
            } header: {
                Text("动态识别测试")
            } footer: {
                Text("点「开始」后会弹出系统内容共享选择，请选整屏 / Entire Display，然后切到微信测试。识别全部在本机进行，本阶段不会上传屏幕图像，也不会自动分析聊天。")
            }

            Section("统计") {
                LabeledContent("收到屏幕帧", value: "\(manager.model.framesReceived)")
                LabeledContent("执行识别次数", value: "\(manager.model.ocrRuns)")
                LabeledContent("节流丢弃帧", value: "\(manager.model.droppedFrames)")
                LabeledContent("识别失败次数", value: "\(manager.model.ocrFailures)")
                if let at = manager.model.lastFrameAt {
                    LabeledContent("最后收到画面", value: Self.timeFormatter.string(from: at))
                }
                if let at = manager.model.lastOCRFinishedAt {
                    LabeledContent("最后识别时间", value: Self.timeFormatter.string(from: at))
                }
            }

            Section {
                if let snapshot = manager.model.snapshot {
                    if snapshot.strings.isEmpty {
                        Text("这一帧没有识别到文字。").foregroundStyle(.secondary)
                    } else {
                        Text(snapshot.fullText)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("还没有识别结果。").foregroundStyle(.secondary)
                }
            } header: {
                Text("最新识别文字")
            } footer: {
                Text("只保留最近一次结果，放在内存里；不保存截图、不写文件。")
            }

            Section {
                LabeledContent("当前屏幕候选", value: "\(manager.chat.candidatesThisFrame)")
                LabeledContent("本帧已稳定", value: "\(manager.chat.stableThisFrame)")
                LabeledContent("待确认", value: "\(manager.chat.pendingCandidates)")
                LabeledContent("时间线消息", value: "\(manager.chat.messages.count)")
                LabeledContent("未确定角色", value: "\(manager.chat.unknownCount)")
                LabeledContent("去重丢弃", value: "\(manager.chat.duplicateDrops)")
                if manager.chat.truncatedOldest > 0 {
                    LabeledContent("超出上限丢弃", value: "\(manager.chat.truncatedOldest)")
                }
                Button("清空实时聊天", role: .destructive) { manager.clearLiveChat() }
                    .disabled(manager.chat.messages.isEmpty)
            } header: {
                Text("实时聊天")
            } footer: {
                Text("只放在内存里，最多 \(LiveChatGeometryConfiguration.default.maxTimelineMessages) 条；不会写共享聊天，也不会自动送去 AI。清空不会停止屏幕捕获。")
            }

            if manager.chat.showsDiscontinuity {
                Section {
                    Label("检测到不连续聊天区域：这一屏和已记录的内容没有可靠重叠，先不拼接。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if manager.chat.messages.isEmpty {
                    Text("还没有稳定消息。切到微信停一会儿，或上下滚动一次。")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(manager.chat.messages.enumerated()), id: \.offset) { _, message in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(message.role.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(roleColor(message.role))
                                    Text(message.text)
                                        .font(.footnote)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            } header: {
                Text("时间线（按识别顺序）")
            } footer: {
                Text("「未确定」表示从几何上看不出归属，它不会被自动算成「我」或「对方」。")
            }

            if case .unsupported = manager.model.state {
                Section {
                    Text("动态屏幕识别需要 iOS 27 或更高版本；截图 OCR、军师分析与回复插入都不受影响。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("动态识别测试")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 角色只用文字标签区分，颜色只是辅助：unknown 必须显眼，不能被藏起来。
    private func roleColor(_ role: LiveChatRole) -> Color {
        switch role {
        case .me: return .blue
        case .other: return .primary
        case .unknown: return .orange
        case .system: return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        LiveScreenCaptureView()
    }
}
