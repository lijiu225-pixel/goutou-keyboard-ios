import SwiftUI

struct AppChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: GoutouChatRole = .other
    var text = ""
}

/// App owns its draft and result in memory. Editing or replacing a draft invalidates in-flight results.
final class AppMentorModel: ObservableObject {
    @Published var messages = [AppChatMessage()] {
        didSet { invalidate() }
    }
    @Published private(set) var result: RecognizedChatResult?
    @Published private(set) var isLoading = false
    @Published var notice: String?
    private var task: URLSessionTask?
    private var generation = UUID()

    func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        result = nil
        notice = nil
    }

    func cancel() {
        invalidate()
        notice = "已取消分析。"
    }

    func loadLatest() {
        do {
            let snapshot = try SharedChatStore().read()
            messages = snapshot.messages.map { AppChatMessage(role: $0.role, text: $0.text) }
            notice = "已读取 \(messages.count) 条聊天，请核对内容与归属。" +
                (snapshot.isOlderThanThirtyMinutes() ? "这份聊天已超过 30 分钟。" : "")
        } catch {
            notice = "读取失败，当前草稿保留。请先到「识别」保存聊天。"
        }
    }

    func analyze() {
        guard !isLoading else { return }
        guard let config = GoutouConfig.load(), config.isReady else {
            notice = "请先到「设置」保存 AI 接口。"; return
        }
        let payload = messages.map { GoutouChatClipboardMessage(role: $0.role, text: $0.text) }
        guard let prompt = RecognizedChatPrompt.userMessage(messages: payload) else {
            notice = "请填写每条消息，或删掉空白消息；聊天过长时请分段分析。"; return
        }
        guard let url = Bundle.main.url(forResource: "GoutouSkill", withExtension: "md"),
              let skill = try? String(contentsOf: url, encoding: .utf8), !skill.trimmed.isEmpty else {
            notice = "缺少军师提示词资源，请更新安装包。"; return
        }
        invalidate()
        let requestID = generation
        isLoading = true
        task = GoutouAIClient.analyzeChat(config: config,
            systemPrompt: RecognizedChatPrompt.systemPrompt(skill: skill), userMessage: prompt) { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self, self.generation == requestID else { return }
                self.isLoading = false
                self.task = nil
                switch response {
                case .success(let fields):
                    switch RecognizedChatResult.normalized(fields) {
                    case .success(let result): self.result = result
                    case .failure(let error): self.notice = error.message
                    }
                case .failure(let error): self.notice = RecognizedChatAnalysisError.ai(error).message
                }
            }
        }
    }

    deinit { task?.cancel() }
}

struct AppMentorView: View {
    @StateObject private var model = AppMentorModel()
    @State private var copiedIndex: Int?
    @State private var confirmReplace = false
    @FocusState private var editing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MentorHero()

                Button {
                    if model.messages.contains(where: { !$0.text.trimmed.isEmpty }) { confirmReplace = true }
                    else { model.loadLatest() }
                } label: {
                    Label("读取最新识别聊天", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity, minHeight: 44).padding(.vertical, 4)
                }.buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("聊天内容").font(.headline)
                        Spacer()
                        Text("\(model.messages.count) 条").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("按聊天发生的顺序添加，每条选择说话的人。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("还没有聊天内容", systemImage: "bubble.left.and.text.bubble.right")
                                .font(.headline)
                            Text("添加第一条消息，或读取你已保存的识别结果。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.appSurface()
                    }
                    ForEach($model.messages) { $message in
                        MentorMessageEditor(message: $message,
                            number: (model.messages.firstIndex(where: { $0.id == message.id }) ?? 0) + 1,
                            delete: { model.messages.removeAll { $0.id == message.id } }, focus: $editing)
                    }
                    Button { model.messages.append(AppChatMessage()) } label: {
                        Label("添加一条消息", systemImage: "plus.circle")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.bordered)
                    .disabled(model.messages.count >= GoutouChatClipboardCodec.maxMessages)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("点击分析会把以上聊天发送到你在设置中配置的 AI 接口。请先核对「我 / 对方」的归属。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        editing = false
                        copiedIndex = nil
                        model.analyze()
                    } label: {
                        HStack {
                            if model.isLoading { ProgressView().tint(.white) }
                            Text(model.isLoading ? "正在分析…" : "分析这段聊天")
                        }.frame(maxWidth: .infinity).padding(.vertical, 9)
                    }.buttonStyle(.borderedProminent)
                        .disabled(model.isLoading || model.messages.isEmpty || model.messages.contains { $0.text.trimmed.isEmpty })
                    if model.isLoading { Button("取消分析") { model.cancel() } }
                    if let notice = model.notice {
                        Label(notice, systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.indigo.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("mentorNotice")
                    }
                }

                if let result = model.result {
                    HStack {
                        Text("军师的建议").font(.title2.bold())
                        Spacer()
                        Label("分析完成", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.teal)
                    }
                    MentorInsightCard(title: "聊天分析", text: result.analysis, icon: "sparkles", accent: .indigo)
                    MentorInsightCard(title: "对方状态", text: result.tone, icon: "person.bubble", accent: .teal)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("选一句适合你的").font(.headline)
                        Text("复制后可再修改，发送由你决定。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(Array(result.replies.enumerated()), id: \.offset) { index, reply in
                        MentorReplyCard(number: index + 1, reply: reply, isCopied: copiedIndex == index) {
                            UIPasteboard.general.string = reply
                            copiedIndex = index
                        }
                    }
                }
            }.padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("军师").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { editing = false }
            }
        }
        .confirmationDialog("用最新识别聊天替换当前草稿？", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("读取并替换") { model.loadLatest() }
            Button("取消", role: .cancel) { }
        }
    }

}
