import SwiftUI

/// Phase-one probe. Sample data is never automatically sent to the AI or inserted.
struct SharedChatTestSection: View {
    @State private var status = ""
    @State private var lastUpdated: Date?
    @State private var notice: String?

    var body: some View {
        Section {
            Text(status)
            if let lastUpdated = lastUpdated {
                LabeledContent("最后写入", value: lastUpdated.formatted(date: .omitted, time: .standard))
            }
            Button("写入示例聊天（通信测试）") {
                perform {
                    try SharedChatStore().save(ChatSnapshot(updatedAt: Date(), messages: [
                        ChatMessage(role: .other, text: "你好", timestamp: nil),
                        ChatMessage(role: .me, text: "你好啊", timestamp: nil)
                    ]))
                }
            }
            Button("刷新共享聊天状态") { refresh() }
            Button("清空共享聊天缓存", role: .destructive) {
                perform { try SharedChatStore().clear() }
            }
            if let notice = notice {
                Text(notice).foregroundStyle(.secondary)
            }
        } header: {
            Text("共享聊天通信测试")
        } footer: {
            Text("写入后切到自测输入框，打开键盘的「军师」面板，应显示共享聊天 2 条。30 秒后重新打开面板应提示过期。此阶段仅测试本机共享，不调用 AI。")
        }
        .onAppear(perform: refresh)
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            notice = nil
        } catch {
            notice = "操作失败，请检查 App Group 签名和设备权限。"
        }
        refresh()
    }

    private func refresh() {
        status = ChatSharingStatus.read()
        lastUpdated = (try? SharedChatStore().load())?.updatedAt
    }
}
