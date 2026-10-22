import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack { AppMentorView() }
                .tabItem { Label("军师", systemImage: "bubble.left.and.bubble.right.fill") }
            NavigationStack { CaptureHomeView() }
                .tabItem { Label("识别", systemImage: "text.viewfinder") }
            NavigationStack { AppSettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(.indigo)
    }
}

private struct CaptureHomeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AppPageIntro(icon: "text.viewfinder", title: "让聊天更好读", subtitle: "选一张截图，或开始动态识别。\n检查后保存，再交给军师分析。")
                VStack(spacing: 14) {
                    NavigationLink { ChatOCRView() } label: {
                        CaptureEntryCard(icon: "photo.on.rectangle.angled", title: "聊天截图", subtitle: "从相册选择截图，逐条检查和修正", badge: "本机识别", color: .indigo)
                    }.buttonStyle(.plain)
                    NavigationLink { LiveScreenCaptureView() } label: {
                        CaptureEntryCard(icon: "rectangle.inset.filled.and.person.filled", title: "动态识别", subtitle: "主动共享屏幕，持续整理聊天内容", badge: "需屏幕授权", color: .teal)
                    }.buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 20) {
                    Text("从识别到回复").font(.headline)
                    CaptureStep(number: "1", title: "获取聊天", detail: "截图识别或动态屏幕识别")
                    CaptureStep(number: "2", title: "检查并保存", detail: "修正文字，确认「我 / 对方」的归属")
                    CaptureStep(number: "3", title: "到军师页分析", detail: "读取最新聊天，分析后复制一条回复")
                }.appSurface()
                Label("截图在本机处理，分析由你主动发起。", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("聊天识别").navigationBarTitleDisplayMode(.inline)
    }
}

private struct CaptureEntryCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                    .frame(width: 48, height: 48).background(color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Spacer()
                Text(badge).font(.caption.weight(.medium)).foregroundStyle(color)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(color.opacity(0.08)).clipShape(Capsule())
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title3.bold()).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").foregroundStyle(color).padding(.top, 4)
            }
        }.appSurface()
    }
}

private struct CaptureStep: View {
    let number: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.subheadline.bold()).foregroundStyle(.indigo)
                .frame(width: 30, height: 30).background(Color.indigo.opacity(0.09)).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct AppPageIntro: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.indigo)
                .frame(width: 52, height: 52).background(Color.indigo.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(title).font(.title2.bold())
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8)
    }
}

private struct AppSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

extension View {
    func appSurface() -> some View { modifier(AppSurface()) }
}

struct AppSettingsView: View {
    @State private var config = GoutouConfig.load() ?? .empty
    @State private var status: String?
    @State private var draft = ""
    @State private var savedConfig = GoutouConfig.load()
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case baseURL, model, key, draft }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("按你的方式使用军师").font(.headline)
                        Text(savedConfig == nil ? "先配置 AI 接口，再开始分析。" : (savedConfig == config ? "接口已保存，可到军师页开始分析。" : "配置有修改，保存后才会用于分析。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("接口地址").font(.caption).foregroundStyle(.secondary)
                    TextField("https://api.example.com/v1", text: $config.baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($focusedField, equals: .baseURL)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("模型名称").font(.caption).foregroundStyle(.secondary)
                    TextField("例如 deepseek-chat", text: $config.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField, equals: .model)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("API Key").font(.caption).foregroundStyle(.secondary)
                    SecureField("输入密钥，自建免鉴权接口可留空", text: $config.apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField, equals: .key)
                }
                if !config.baseURL.trimmed.isEmpty && config.chatCompletionsURL == nil {
                    Label("请输入包含 http:// 或 https:// 的有效地址。", systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Button("保存接口配置") {
                    config.save()
                    savedConfig = config
                    focusedField = nil
                    status = "已保存，App 内分析可直接使用。"
                }.disabled(!validConfig)
                Button("复制配置给键盘") {
                    config.save()
                    savedConfig = config
                    focusedField = nil
                    UIPasteboard.general.string = config.exportText
                    status = "已复制。去键盘「军师 → 设置 → 从剪贴板导入」。"
                }.disabled(!validConfig)
                if let status = status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("AI 接口") } footer: {
                Text("例如 https://api.deepseek.com/v1。点击分析时，聊天文字会发送到这里配置的接口。配置保存在本机，App 和键盘需分别配置。")
            }
            Section("键盘") {
                Text("设置 → 通用 → 键盘 → 添加新键盘 → 狗头军师。键盘内联网分析需开启「允许完全访问」。")
                TextField("在这里试试九键或英文输入", text: $draft, axis: .vertical)
                    .lineLimit(3...6).focused($focusedField, equals: .draft)
            }
            Section("诊断") {
                NavigationLink("App Group 共享诊断") { AppGroupDiagnosticView() }
            }
            Section("关于") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                Text("回复由你复制或插入，发送前请自行确认。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: config) { _ in status = nil }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
    }

    private var validConfig: Bool { config.isReady && config.chatCompletionsURL != nil }
}
