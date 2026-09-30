import SwiftUI

/// 宿主 App：配置军师接口 + 启用向导 + 自测输入框。
///
/// 配置在这里填（这里能用系统键盘、能粘贴），点「复制配置」，
/// 回键盘的「军师 → ⚙ 设置 → 从剪贴板导入」。
/// 接口配置仍走原有剪贴板通道；聊天内容改走「截图 OCR → 剪贴板」通道，不依赖 App Group。
struct ContentView: View {
    @State private var draft = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var copied = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var config: GoutouConfig {
        GoutouConfig(baseURL: baseURL, model: model, apiKey: apiKey)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 90)
                        .overlay(alignment: .topLeading) {
                            if draft.isEmpty {
                                Text("切到「狗头军师」键盘，在这儿打几个字试试")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("自测输入框")
                } footer: {
                    Text("九键：按 6 4 4 2 6 出「你好」。顶栏「军师」进面板。")
                }

                Section {
                    NavigationLink {
                        ChatOCRView()
                    } label: {
                        Label("识别聊天截图", systemImage: "text.viewfinder")
                    }
                } header: {
                    Text("聊天截图识别")
                } footer: {
                    Text("截一张聊天图 → 本机识别 → 你检查并修正归属 → 点「复制聊天文字」。截图只在这台手机上处理，不保存、不上传；剪贴板只在你自己点复制时才写。这一步只到你手上为止：键盘那边还没有导入入口，识别结果暂时不会进 AI 分析。")
                }

                Section {
                    NavigationLink("动态识别测试") { LiveScreenCaptureView() }
                } header: {
                    Text("动态屏幕识别（实验）")
                } footer: {
                    Text("用户主动授权整屏共享后，主 App 会持续收到屏幕画面，并在本机把画面文字识别出来给你看。本阶段只验证捕获链路：不自动分析、不写聊天、不保存截图。")
                }

                Section {
                    NavigationLink("App Group 诊断") { AppGroupDiagnosticView() }
                }

                Section {
                    TextField("Base URL，例如 https://api.example.com/v1", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Model，例如 gpt-4o-mini", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        copyConfig()
                    } label: {
                        Label(
                            copied ? "已复制，去键盘点「⚙ 设置 → 从剪贴板导入」" : "复制配置到剪贴板",
                            systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                    }
                    .disabled(!config.isReady)
                } header: {
                    Text("军师接口")
                } footer: {
                    Text(config.isReady
                        ? "Base URL 填到 /v1 就行（会自动补 /chat/completions）。key 只存在这台手机上，不进代码仓库，也不上传到别处。"
                        : "填好 Base URL 和 Model 才能复制。key 可以留空（自建接口不需要鉴权时）。")
                }

                Section("把键盘加到系统里") {
                    StepRow(index: 1, text: "设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 第三方键盘 → 狗头军师")
                    StepRow(index: 2, text: "点「狗头军师」→ 打开「允许完全访问」（军师要读剪贴板、要联网，不开就用不了）")
                    StepRow(index: 3, text: "回到输入框，长按 🌐 切到这个键盘")
                }

                Section("用军师的三步") {
                    StepRow(index: 1, text: "长按对方的消息 → 复制")
                    StepRow(index: 2, text: "键盘顶栏点「军师」→ 点 👤对方（自己的话点 🙋我，背景点 📝背景）")
                    StepRow(index: 3, text: "点 ⟳ 分析 → 选一条话术上屏（不会自动发送）")
                }

                // 用 header:/footer: 的显式形式：`Section("标题") { } footer: { }` 是 iOS 17 才有的重载，
                // 本工程 deploymentTarget 是 iOS 16，加了 footer 会编译不过。
                Section {
                    StepRow(index: 1, text: "截图工具截下聊天界面，回这里点「识别聊天截图」并选那张图")
                    StepRow(index: 2, text: "检查识别结果：改错的字、定「未确定」的归属、左滑删掉状态栏和标题")
                    StepRow(index: 3, text: "点「复制聊天文字」，结果 JSON 进剪贴板。键盘侧「导入识别聊天」还没做，复制完先放着")
                } header: {
                    Text("用截图 OCR 聊天记录（本阶段只到复制为止）")
                } footer: {
                    Text("这一步不联网、不上传截图、不保存图片，也不会自动写剪贴板。下一阶段才接键盘导入和 AI 分析。")
                }

                Section("关于") {
                    LabeledContent("版本", value: "v\(version) (build \(buildNumber))")
                    LabeledContent("词库", value: "20 词（与 Android 版同源）")
                    LabeledContent("联网", value: "只发你配置的那个接口")
                }
            }
            .navigationTitle("狗头军师输入法")
            .onAppear(perform: loadStoredConfig)
        }
    }

    private func copyConfig() {
        UIPasteboard.general.string = config.exportText
        config.save()
        copied = true
    }

    private func loadStoredConfig() {
        guard let stored = GoutouConfig.load() else { return }
        baseURL = stored.baseURL
        model = stored.model
        apiKey = stored.apiKey
    }
}

private struct StepRow: View {
    let index: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index)")
                .font(.footnote.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text)
        }
    }
}

#Preview {
    ContentView()
}
