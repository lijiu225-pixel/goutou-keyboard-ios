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
        List {
            Section {
                Label("把聊天带给军师", systemImage: "text.viewfinder")
                    .font(.title2.bold()).padding(.vertical, 12)
                Text("识别后检查文字和归属，保存给狗头军师，再到「军师」读取最新聊天。")
                    .foregroundStyle(.secondary)
            }
            Section {
                NavigationLink { ChatOCRView() } label: {
                    Label("从聊天截图识别", systemImage: "photo.on.rectangle")
                }
                NavigationLink { LiveScreenCaptureView() } label: {
                    Label("动态屏幕识别", systemImage: "rectangle.inset.filled.and.person.filled")
                }
            } footer: {
                Text("截图在本机识别。动态识别需要系统支持并由你主动授权屏幕共享；自动同步需每次开启。")
            }
        }
        .navigationTitle("聊天识别")
    }
}

struct AppSettingsView: View {
    @State private var config = GoutouConfig.load() ?? .empty
    @State private var status: String?
    @State private var draft = ""

    var body: some View {
        Form {
            Section {
                TextField("Base URL", text: $config.baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Model", text: $config.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API Key（可选）", text: $config.apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存接口配置") {
                    config.save()
                    status = "已保存，App 内分析可直接使用。"
                }.disabled(!validConfig)
                Button("复制配置给键盘") {
                    config.save()
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
                    .lineLimit(3...6)
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
    }

    private var validConfig: Bool { config.isReady && config.chatCompletionsURL != nil }
}
