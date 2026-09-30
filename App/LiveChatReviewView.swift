import SwiftUI

/// 阶段 12C：把冻结的实时聊天快照交给用户做**最终确认**，再复用现有 SharedChatStore 保存。
///
/// 这里不碰屏幕捕获、不调 AI、不写键盘上下文、不插入任何文字、也不自动发送。
struct LiveChatReviewView: View {

    @ObservedObject var manager: LiveScreenCaptureManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let draft = manager.reviewDraft {
                summarySection(draft)
                messagesSection(draft)
                actionSection
            } else {
                Section {
                    Text("没有正在确认的实时聊天。回上一页点「整理当前实时聊天」。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("确认实时聊天")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summarySection(_ draft: LiveChatReviewDraft) -> some View {
        Section {
            LabeledContent("这一份快照", value: "\(draft.messages.count) 条")
            LabeledContent("保留", value: "\(draft.includedCount) 条")
            LabeledContent("未确定", value: "\(draft.unresolvedUnknownCount) 条")
            if draft.systemCount > 0 {
                LabeledContent("系统（默认排除）", value: "\(draft.systemCount) 条")
            }
        } footer: {
            Text("这是点「整理当前实时聊天」那一刻的冻结副本；之后新识别的消息不会插进来，想带上它们就返回再整理一次。")
        }
    }

    private func messagesSection(_ draft: LiveChatReviewDraft) -> some View {
        Section {
            ForEach(draft.messages) { message in
                messageRows(message)
            }
        } header: {
            Text("逐条确认")
        } footer: {
            Text("正文可以直接改，改完的才是保存内容。角色拿不准就留在「未确定」——保存前必须先处理掉；排除掉的不会写进共享聊天。")
        }
    }

    private var actionSection: some View {
        Section {
            Button("保存给狗头军师") { manager.saveLiveChatReview() }
            Button("放弃这次整理", role: .destructive) {
                manager.cancelLiveChatReview()
                dismiss()
            }
        } footer: {
            if let note = manager.reviewNote {
                Text(note).font(.footnote)
            } else {
                Text("保存只写入共享聊天，不自动分析、不自动插入，也不自动发送。写完去键盘点「读取识别聊天」就会读到这份内容。")
            }
        }
    }

    @ViewBuilder
    private func messageRows(_ message: LiveChatReviewMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if message.isSystem {
                    Text("系统 / 已排除")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("归属", selection: Binding(
                        get: { message.role },
                        set: { manager.setReviewRole(id: message.id, role: $0) }
                    )) {
                        Text(LiveChatRole.me.displayName).tag(LiveChatRole.me)
                        Text(LiveChatRole.other.displayName).tag(LiveChatRole.other)
                        Text(LiveChatRole.unknown.displayName).tag(LiveChatRole.unknown)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Spacer()

                if !message.isSystem {
                    Toggle("保留", isOn: Binding(
                        get: { message.isIncluded },
                        set: { manager.setReviewIncluded(id: message.id, isIncluded: $0) }
                    ))
                    .labelsHidden()
                }
            }

            TextField("正文", text: Binding(
                get: { message.text },
                set: { manager.setReviewText(id: message.id, text: $0) }
            ), axis: .vertical)
            .lineLimit(1...6)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            if message.originalRole != message.role {
                Text("原来是「\(message.originalRole.displayName)」")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        LiveChatReviewView(manager: LiveScreenCaptureManager())
    }
}
