import Photos
import PhotosUI
import SwiftUI
import UIKit

/// 主 App 的截图 OCR、人工修正、手动复制与共享保存页。
///
/// 选图 → 本机识别 → 人工检查修正 → 手动复制或保存。
/// - **不**自动写剪贴板（只有点「复制聊天文字」才写）；
/// - **不**调用 AI；
/// - **不**保存图片：UIImage 只作为局部变量活在识别过程中，@State 里只留文字和框；
/// - 共享聊天只供键盘独立预览，不进入 AI 或人物记忆。
///
/// 第二阶段新增的两点：
/// 1. 顶部状态栏/标题、底部输入区/键盘这些**确定不是聊天**的内容直接不进列表，只报个数；
/// 2. 居中的日期时间、系统提示、通话记录标成「非聊天候选」，**默认不复制**，用户可一键放回。
struct ChatOCRView: View {

    /// 低于这个置信度就在那一条旁边标「可能认错」，提醒用户重点核对。
    private static let lowConfidence: Float = 0.5

    @State private var pickerItem: PhotosPickerItem?
    @State private var messages: [ChatLayoutMessage] = []
    /// 被自动剔掉的内容按原因汇总（只有数字，没有文字）。
    @State private var excludedCounts: [ChatLayoutExcludedCount] = []
    @State private var stage: Stage = .idle
    @State private var notice: String?
    /// 复制成功后的提示（只说条数和字数，不回显聊天内容）。
    @State private var copiedNote: String?
    /// 有「未确定」的归属时，复制前先问怎么算。
    @State private var isShowingUnresolvedPrompt = false
    private enum ExportDestination { case clipboard, sharedChat }
    @State private var exportDestination: ExportDestination = .clipboard

    /// 当前这次识别的任务。换图 / 清空 / 退出页面时取消它。
    @State private var recognitionTask: Task<Void, Never>?
    /// 请求标识：每发起一次识别、每次清空或退出都 +1。
    ///
    /// 任务在每一步 await 之后都要拿自己的标识和当前值比对，对不上就直接返回，
    /// 一个字节都不写回界面。这样「清空 / 换图 / 退出」之后，旧任务即使跑完也污染不了状态。
    /// 只有**当前**标识对应的任务才允许改 stage 和 messages。
    @State private var recognitionRequestID = 0

    private enum Stage: Equatable {
        case idle
        case loading
        case done(count: Int)
        case cancelled
        case failed(String)

        var text: String {
            switch self {
            case .idle:
                return "选一张聊天截图开始。"
            case .loading:
                return "正在本机识别…"
            case .done(let count):
                return count > 0 ? "识别完成，整理出 \(count) 条聊天消息。" : "识别完成，但这张图里没有可用的聊天文字。"
            case .cancelled:
                return "已取消识别。"
            case .failed(let reason):
                return reason
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }

        var isLoading: Bool {
            self == .loading
        }
    }

    // MARK: - 派生状态

    private var chatIndexes: [Int] {
        messages.indices.filter { messages[$0].kind.isChat }
    }

    private var candidateIndexes: [Int] {
        messages.indices.filter { messages[$0].kind.isCandidate }
    }

    /// 真正会写进剪贴板的那些（用户保留 + 归属已定）。
    private var keptIndexes: [Int] {
        messages.indices.filter { messages[$0].isKept }
    }

    /// 只有「保留着、而且是聊天消息、归属还没定」的才需要用户定。
    private var unresolvedCount: Int {
        messages.filter { $0.isKept && $0.needsReview }.count
    }

    private var canCopy: Bool {
        !messages.isEmpty && !stage.isLoading
    }

    var body: some View {
        Form {
            pickerSection
            if !messages.isEmpty {
                if !candidateIndexes.isEmpty {
                    candidateSection
                }
                resultSection
            }
            actionSection
            if let copiedNote = copiedNote {
                Section {
                    Label(copiedNote, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("识别聊天截图")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { item in
            guard let item = item else { return }
            startRecognition(item)
        }
        // 退出这一页：取消在跑的任务并作废它的标识，结果不允许再更新界面。
        .onDisappear(perform: abandonRecognition)
        .confirmationDialog(
            "还有 \(unresolvedCount) 条不知道是谁说的",
            isPresented: $isShowingUnresolvedPrompt,
            titleVisibility: .visible
        ) {
            Button("未确定的算「对方」") { performCopy(treatingUnknownAs: .other) }
            Button("未确定的算「我」") { performCopy(treatingUnknownAs: .me) }
            Button("先不处理", role: .cancel) {}
        } message: {
            Text("选一个，我会先把这几条的归属改掉，再完成你点击的复制或保存。也可以取消后逐条核对。")
        }
    }

    // MARK: - 选图

    private var pickerSection: some View {
        Section {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Label("选择聊天截图", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(stage.isLoading)

            HStack(spacing: 8) {
                if stage.isLoading {
                    ProgressView()
                    Button("取消") { cancelRecognition() }
                        .font(.footnote)
                }
                Text(stage.text)
                    .font(.footnote)
                    // 两个分支必须是同一个类型，否则三元推断不出来。
                    .foregroundStyle(stage.isFailure ? Color.red : Color.secondary)
            }

            if let notice = notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if !excludedCounts.isEmpty {
                Text(excludedSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("截图")
        } footer: {
            Text("截图只在这台手机上识别，不保存图片、不上传。识别可能认错字，「未确定」是版式上看不出归属，都需要你顺手改一下。很长的截图会自动分片识别，尽可能保住文字清晰度。")
        }
    }

    /// 被自动剔掉的内容只说个数和类型，不回显文字。
    private var excludedSummary: String {
        let parts = excludedCounts.map { "\($0.reason.displayName) \($0.count) 条" }
        return "默认不复制：" + parts.joined(separator: "、") + "。可在下方候选区核对和恢复。"
    }

    // MARK: - 非聊天候选

    private var candidateSection: some View {
        Section {
            ForEach(candidateIndexes, id: \.self) { index in
                row(for: $messages[index], showsRolePicker: false)
                Toggle("保留这条，加入保存或复制", isOn: $messages[index].isKept)
                if messages[index].isKept {
                    Picker("这条是谁说的", selection: $messages[index].role) {
                        ForEach(ChatLayoutRole.selectable, id: \.self) { role in
                            Text(role.displayName).tag(role)
                        }
                    }
                }
            }
            Button("把这些都算进聊天") { setCandidates(kept: true) }
            Button("全部删掉", role: .destructive) { removeCandidates() }
        } header: {
            Text("非聊天内容（默认不复制）")
        } footer: {
            Text("这些可能是日期、通话状态、页眉页脚或键盘。判断可能出错，请核对；真实消息可逐条保留并修改归属。默认不复制。")
        }
    }

    // MARK: - 可编辑结果

    private var resultSection: some View {
        Section {
            ForEach(chatIndexes, id: \.self) { index in
                row(for: $messages[index], showsRolePicker: true)
            }
            .onDelete { offsets in
                let targets = offsets.map { chatIndexes[$0] }
                messages.remove(atOffsets: IndexSet(targets))
            }

            Menu {
                Button("把未确定的都设为「对方」") { setUnknown(to: .other) }
                Button("把未确定的都设为「我」") { setUnknown(to: .me) }
                Divider()
                Button("反转全部归属（我 ↔ 对方）") { flipAll() }
                Divider()
                Button("清掉末尾的表情乱码") { applySymbolNoiseSuggestions() }
            } label: {
                Label("批量修正", systemImage: "wand.and.stars")
            }
            .disabled(chatIndexes.isEmpty)
        } header: {
            Text("聊天消息（可编辑）")
        } footer: {
            Text(resultFooter)
        }
    }

    /// 单独算成 String，避免 Text(三元) 在 String / LocalizedStringKey 之间打摆子。
    private var resultFooter: String {
        if unresolvedCount > 0 {
            return "还有 \(unresolvedCount) 条是「未确定」，复制时会问你怎么算。左右可能判反了的话，用「批量修正 → 反转」。"
        }
        return "每条都能改归属和文字；左滑可以删掉多余的行。"
    }

    private func row(for message: Binding<ChatLayoutMessage>, showsRolePicker: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if showsRolePicker {
                    Picker("归属", selection: message.role) {
                        ForEach(ChatLayoutRole.selectable, id: \.self) { role in
                            Text(role.displayName).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                } else if let reason = message.wrappedValue.kind.reason {
                    Text(reason.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if message.wrappedValue.confidence < Self.lowConfidence {
                    Text("可能认错")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            TextField("文字", text: message.text, axis: .vertical)
                .lineLimit(1...8)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if message.wrappedValue.hasSuggestedText, let suggestion = message.wrappedValue.suggestedText {
                HStack(spacing: 8) {
                    Text("末尾像是表情被认错了")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button("去掉末尾杂字") {
                        message.wrappedValue.text = suggestion
                    }
                    .font(.caption2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            Button {
                exportDestination = .sharedChat
                requestExport()
            } label: {
                Label("保存给狗头军师", systemImage: "square.and.arrow.down")
            }
            .disabled(!canCopy)

            Button {
                copyChat()
            } label: {
                Label("复制聊天文字", systemImage: "doc.on.clipboard")
            }
            .disabled(!canCopy)

            Button("清除已共享聊天（键盘将无法读取）", role: .destructive) {
                copiedNote = nil
                do {
                    try SharedChatStore().clear()
                    notice = "已清除共享聊天；当前识别和编辑结果仍保留。"
                } catch {
                    notice = error.localizedDescription
                }
            }

            Button("清空识别结果", role: .destructive) {
                clearResults()
            }
            .disabled(messages.isEmpty && pickerItem == nil && !stage.isLoading)

            if stage.isLoading {
                Button("取消识别", role: .cancel) { cancelRecognition() }
            }
        } header: {
            Text("保存与复制")
        } footer: {
            Text("点击才保存或复制，只包含你保留的消息。保存后可在键盘点「读取识别聊天」预览。清空识别结果不会删除共享聊天。共享组由签名服务提供，项目子目录只避免文件重名，不隔离同组其他应用；清除共享聊天可删除这份保存内容。")
        }
    }

    // MARK: - 识别任务生命周期

    /// 发起一次识别。前一次任务会被取消并作废。
    private func startRecognition(_ item: PhotosPickerItem) {
        abandonRecognition()
        recognitionRequestID += 1
        let requestID = recognitionRequestID
        // 换图即清空：上一张图的结果不能留在这里，也不能在稍后被写回来。
        stage = .loading
        notice = nil
        copiedNote = nil
        messages = []
        excludedCounts = []
        recognitionTask = Task { await recognize(item, requestID: requestID) }
    }

    /// 取消在跑的任务并作废它的标识（结果一律不再更新界面）。
    private func abandonRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequestID += 1
    }

    /// 用户主动取消：作废结果，但保留用户已经改好的内容（如果已经识别出东西的话）。
    private func cancelRecognition() {
        guard stage.isLoading else { return }
        abandonRecognition()
        stage = .cancelled
        notice = "已停止识别，可以换一张图再试。"
    }

    /// 清空时把选图和识别结果一起放掉，不在内存里留截图；在跑的任务一并作废。
    private func clearResults() {
        abandonRecognition()
        messages = []
        excludedCounts = []
        pickerItem = nil
        stage = .idle
        notice = nil
        copiedNote = nil
    }

    /// 显式回到主线程改界面；识别本身在 ChatOCRService 的后台队列里跑。
    ///
    /// 每个 await 之后都会 guard requestID == recognitionRequestID：
    /// 清空 / 换图 / 退出页面都会让标识对不上，任务就此收手。
    @MainActor
    private func recognize(_ item: PhotosPickerItem, requestID: Int) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                guard isCurrent(requestID) else { return }
                stage = .idle
                notice = "没读到图片数据（可能是取消了选择）。"
                return
            }
            guard isCurrent(requestID) else { return }
            guard let image = UIImage(data: data) else {
                stage = .idle
                notice = "这个文件不是图片，换一张聊天截图。"
                return
            }

            // 这里开始是 Vision：ChatOCRService.recognize 内部还有一次后台线程切换，
            // 片与片之间才检查取消（perform 本身打断不了）。
            let result = try await ChatOCRService.recognize(image: image)
            try Task.checkCancellation()
            guard isCurrent(requestID) else { return }

            guard !result.isEmpty else {
                stage = .done(count: 0)
                excludedCounts = []
                notice = result.strategy == .tiled
                    ? "这张长截图分片识别后也没找到文字。尽量只截聊天区域，别带太多空白和背景。"
                    : "这张图没识别到文字。尽量只截聊天区域，别带太多空白和背景。"
                return
            }

            let analysis = ChatLayoutParser.analyze(lines: result.lines)
            messages = analysis.reviewMessages
            excludedCounts = analysis.excludedCounts
            let chatCount = analysis.messages.filter { $0.kind.isChat }.count
            stage = .done(count: chatCount)
            let unresolved = analysis.messages.filter { $0.kind.isChat && $0.needsReview }.count
            // 长图走的是分片识别，用户有权知道「这次是按原图分辨率分片识的」。
            var notes: [String] = []
            if result.strategy == .tiled {
                notes.append("长截图已分片识别，文字按原图分辨率保留。")
            }
            if unresolved > 0 {
                notes.append("有 \(unresolved) 条看不出是谁说的，先标成「未确定」了。")
            }
            let candidates = analysis.messages.filter { $0.kind.isCandidate }.count
            if candidates > 0 {
                notes.append("另有 \(candidates) 条像是系统内容，默认不复制。")
            }
            notice = notes.isEmpty ? nil : notes.joined(separator: " ")
        } catch is CancellationError {
            // 取消不是失败：只有当自己还是当前任务时才动状态
            //（换图 / 清空的场景下，新任务已经接管了界面，这里什么都不该写）。
            guard isCurrent(requestID) else { return }
            stage = .cancelled
            notice = "已停止识别，可以换一张图再试。"
        } catch let error as ChatOCRError {
            guard isCurrent(requestID) else { return }
            stage = .failed(error.localizedDescription)
        } catch {
            guard isCurrent(requestID) else { return }
            stage = .failed("识别失败：\(error.localizedDescription)")
        }
    }

    /// 只有标识还是当前值的那次识别才有资格改界面。
    private func isCurrent(_ requestID: Int) -> Bool {
        requestID == recognitionRequestID
    }

    // MARK: - 手动导出

    /// 有「未确定」时先问用户怎么算，再决定复制什么。
    private func copyChat() {
        exportDestination = .clipboard
        requestExport()
    }

    private func requestExport() {
        copiedNote = nil
        guard unresolvedCount == 0 else {
            notice = nil
            isShowingUnresolvedPrompt = true
            return
        }
        performCopy(treatingUnknownAs: nil)
    }

    /// fallback 为 nil 时表示「已经没有未确定了」。
    ///
    /// 分成「问」和「算 + 导出」两步：确认对话框里的按钮负责指定归属再保存或复制，
    /// 不顺手改 @State（在 ViewBuilder 里改状态容易出顺序问题）。
    private func performCopy(treatingUnknownAs fallback: GoutouChatRole?) {
        if let fallback = fallback {
            applyUnknown(as: fallback)
        }

        var payloadMessages: [GoutouChatClipboardMessage] = []
        for message in messages where message.isKept {
            guard let role = message.role.clipboardRole else {
                // 走不到：上面已经补过了。真到了这里就退回去让用户决定，不要瞎写。
                isShowingUnresolvedPrompt = true
                return
            }
            payloadMessages.append(GoutouChatClipboardMessage(role: role, text: message.text))
        }

        guard !payloadMessages.isEmpty else {
            notice = "没有要保存或复制的内容：非聊天候选默认不带，确认要的话先把它们放回来。"
            return
        }

        do {
            let payload = GoutouChatClipboardPayload(messages: payloadMessages)
            switch exportDestination {
            case .clipboard:
                UIPasteboard.general.string = try GoutouChatClipboardCodec.encode(payload)
                copiedNote = "已复制 \(payloadMessages.count) 条到剪贴板。"
            case .sharedChat:
                let saved = try SharedChatStore().save(payload)
                copiedNote = "已保存 \(saved.messages.count) 条聊天，去键盘点『读取识别聊天』。"
            }
            notice = nil
        } catch {
            // 错误文案里只说第几条出了什么问题，不回显聊天内容。
            notice = error.localizedDescription
        }
    }

    private func applyUnknown(as role: GoutouChatRole) {
        guard let layoutRole = ChatLayoutRole(rawValue: role.rawValue) else { return }
        setUnknown(to: layoutRole)
    }

    private func setUnknown(to role: ChatLayoutRole) {
        for index in messages.indices where messages[index].isKept && messages[index].needsReview {
            messages[index].role = role
        }
        recomputeNotice()
    }

    private func flipAll() {
        for index in messages.indices where messages[index].kind.isChat {
            switch messages[index].role {
            case .me: messages[index].role = .other
            case .other: messages[index].role = .me
            case .unknown: break
            }
        }
        recomputeNotice()
    }

    /// 把「末尾像是表情被认错」的那些一次改完（用户点了才动）。
    private func applySymbolNoiseSuggestions() {
        var changed = 0
        for index in messages.indices {
            guard messages[index].kind.isChat, let suggestion = messages[index].suggestedText else { continue }
            guard messages[index].text != suggestion else { continue }
            messages[index].text = suggestion
            changed += 1
        }
        notice = changed > 0 ? "已清掉 \(changed) 条的末尾杂字，请再核对一遍。" : "没有可清理的末尾杂字。"
    }

    private func setCandidates(kept: Bool) {
        for index in candidateIndexes {
            messages[index].isKept = kept
        }
        copiedNote = nil
        notice = kept ? "非聊天内容已放回，会一起复制。" : nil
    }

    private func removeCandidates() {
        for index in candidateIndexes.reversed() {
            messages.remove(at: index)
        }
        notice = nil
    }

    private func recomputeNotice() {
        let unresolved = unresolvedCount
        notice = unresolved > 0 ? "还有 \(unresolved) 条是「未确定」。" : nil
    }
}

#Preview {
    NavigationStack {
        ChatOCRView()
    }
}
