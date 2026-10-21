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
                VStack(alignment: .leading, spacing: 8) {
                    Label("狗头军师", systemImage: "pawprint.fill")
                        .font(.title.bold()).foregroundStyle(.indigo)
                    Text("聊得明白，回得自然。")
                        .font(.title3).foregroundStyle(.secondary)
                    Text("添加聊天或读取识别结果，在 App 里分析并复制回复。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.top, 8)

                Button {
                    if model.messages.contains(where: { !$0.text.trimmed.isEmpty }) { confirmReplace = true }
                    else { model.loadLatest() }
                } label: {
                    Label("读取最新识别聊天", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("聊天内容").font(.headline)
                        Spacer()
                        Text("\(model.messages.count) 条").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach($model.messages) { $message in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Picker("说话的人", selection: $message.role) {
                                    Text("对方").tag(GoutouChatRole.other)
                                    Text("我").tag(GoutouChatRole.me)
                                }.pickerStyle(.segmented).frame(maxWidth: 180)
                                Spacer()
                                Button(role: .destructive) {
                                    model.messages.removeAll { $0.id == message.id }
                                } label: { Image(systemName: "trash") }
                                    .accessibilityLabel("删除这条消息")
                            }
                            TextField("输入或粘贴这条消息", text: $message.text, axis: .vertical)
                                .lineLimit(2...8).focused($editing)
                        }.padding(14)
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Button { model.messages.append(AppChatMessage()) } label: {
                        Label("添加一条消息", systemImage: "plus.circle")
                    }.disabled(model.messages.count >= GoutouChatClipboardCodec.maxMessages)
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
                        .disabled(model.isLoading || model.messages.isEmpty)
                    if model.isLoading { Button("取消分析") { model.cancel() } }
                    if let notice = model.notice {
                        Text(notice).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("mentorNotice")
                    }
                }

                if let result = model.result {
                    resultCard("聊天分析", text: result.analysis, icon: "sparkles")
                    resultCard("对方状态", text: result.tone, icon: "person.bubble")
                    Text("选一句，复制后再发送").font(.headline)
                    ForEach(Array(result.replies.enumerated()), id: \.offset) { index, reply in
                        VStack(alignment: .leading, spacing: 14) {
                            Text("回复 \(index + 1)").font(.caption.bold()).foregroundStyle(.indigo)
                            Text(reply).textSelection(.enabled)
                            Button {
                                UIPasteboard.general.string = reply
                                copiedIndex = index
                            } label: {
                                Label(copiedIndex == index ? "已复制" : "复制回复",
                                      systemImage: copiedIndex == index ? "checkmark" : "doc.on.doc")
                            }.buttonStyle(.bordered)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                }
            }.padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
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

    private func resultCard(_ title: String, text: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            Text(text).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
