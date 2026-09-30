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
}

#Preview {
    NavigationStack {
        LiveScreenCaptureView()
    }
}
