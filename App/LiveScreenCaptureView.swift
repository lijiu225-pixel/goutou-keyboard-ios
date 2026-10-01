import SwiftUI

/// 阶段 12A 的独立测试页：只证明「用户主动授权整屏 → 主 App 在后台仍能收到屏幕帧 →
/// 本机 Vision 能识别出画面文字」。不做聊天结构、不做我/对方、不联网、不调用 AI。
struct LiveScreenCaptureView: View {

    @ObservedObject var manager: LiveScreenCaptureManager
    @State private var showsReview = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        Form {
            Section {
                LabeledContent("识别门控", value: manager.sceneVerdict.title)
                LabeledContent("状态", value: manager.model.state.title)
                if manager.reviewDraft == nil, let note = manager.reviewNote {
                    Text(note).foregroundStyle(.secondary)
                }
                Button("开始动态识别") { manager.start() }
                    .disabled(!manager.model.state.canStart)
                Button("停止动态识别", role: .destructive) { manager.stop() }
                    .disabled(!manager.model.state.canStop)
            } header: {
                Text("动态识别")
            } footer: {
                Text("点「开始」后会弹出系统内容共享选择，请选整屏 / Entire Display，然后切到微信测试。识别全部在本机进行，本阶段不会上传屏幕图像，也不会自动分析聊天。")
            }

            Section {
                if let diagnostics = manager.sceneDiagnostics {
                    LabeledContent("置信度", value: String(format: "%.2f", Double(diagnostics.confidence)))
                    LabeledContent("顶部导航", value: diagnostics.hasNavigationBar ? "是" : "否")
                    LabeledContent("底部输入栏", value: diagnostics.hasInputBar ? "是" : "否")
                    LabeledContent("左消息行", value: "\(diagnostics.leftCount)")
                    LabeledContent("右消息行", value: "\(diagnostics.rightCount)")
                    LabeledContent("正文行", value: "\(diagnostics.messageRowCount)")
                    LabeledContent("居中系统行", value: "\(diagnostics.centeredCount)")
                    LabeledContent("底部 tab 命中", value: "\(diagnostics.tabBarLineCount)")
                    LabeledContent("进入连续帧", value: "\(diagnostics.enterStreak)")
                    LabeledContent("退出连续帧", value: "\(diagnostics.exitStreak)")
                    LabeledContent("联系人归属已确认", value: diagnostics.hasConfirmedTitle ? "是" : "否")
                    LabeledContent("允许消息提交", value: diagnostics.allowsSubmission ? "是" : "否")
                    LabeledContent("完整 OCR 行数", value: "\(diagnostics.rawObservationCount)")
                    LabeledContent("暂存识别帧", value: "\(diagnostics.bufferedFrames)")
                    LabeledContent("聊天代际", value: "\(diagnostics.chatGeneration)")
                    if let reason = diagnostics.recognitionHoldReason {
                        LabeledContent("等待原因", value: reason)
                    }
                } else {
                    Text("还没有检测帧。开始动态识别并切到微信后这里会显示每项证据。")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("门控诊断")
            } footer: {
                Text("只显示结构与计数，不含聊天正文。判定规则：底部有输入栏且（顶部有导航条或中部有消息行）→ 已进入聊天；或者中部同时有偏左和偏右的气泡行（列表与信息流做不到）也判为已进入聊天。")
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
                        Text(manager.sceneDiagnostics?.recognitionHoldReason ?? "这一帧没有识别到文字。")
                            .foregroundStyle(.secondary)
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
                Button("整理当前实时聊天") {
                    manager.beginLiveChatReview()
                    showsReview = true
                }
                .disabled(manager.chat.messages.isEmpty)
                Button("清空实时聊天（不影响已共享聊天）", role: .destructive) { manager.clearLiveChat() }
                    .disabled(manager.chat.messages.isEmpty)
            } header: {
                Text("实时聊天")
            } footer: {
                Text("只放在内存里，最多 \(LiveChatGeometryConfiguration.default.maxTimelineMessages) 条；不会自动送去 AI。「整理当前实时聊天」会把这一刻冻结成一份快照，让你改完再保存给键盘；清空只清这里的实时结果，不会停止屏幕捕获、也不会删除已经共享给键盘的聊天。")
            }

            Section {
                Toggle("自动同步给狗头军师", isOn: Binding(
                    get: { manager.isAutoSyncEnabled },
                    set: { manager.setAutoSyncEnabled($0) }
                ))
                LabeledContent("状态", value: manager.autoSyncState.title)
                if let at = manager.autoSyncLastSyncAt {
                    LabeledContent("最后成功同步", value: "\(manager.autoSyncLastCount) 条 · \(Self.timeFormatter.string(from: at))")
                }
                if case .pausedAfterManualSave = manager.autoSyncState {
                    Button("继续自动同步") { manager.setAutoSyncEnabled(true) }
                }
            } header: {
                Text("自动同步")
            } footer: {
                Text("开启后，角色明确且稳定的实时聊天会自动更新到共享聊天，你不用每次回来整理保存。不会自动分析、不会自动插入、也不会自动发送；每次重新开始捕获都要重新开启。有「未确定」的消息时会暂停自动同步并保留上一份成功结果；人工确认保存过之后也会暂停，需要你再次主动开启。")
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
        .navigationDestination(isPresented: $showsReview) {
            LiveChatReviewView(manager: manager)
        }
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
        LiveScreenCaptureView(manager: LiveScreenCaptureManager())
    }
}
