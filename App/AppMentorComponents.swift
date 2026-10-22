import SwiftUI

struct MentorHero: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "pawprint.fill").font(.title)
                    .frame(width: 56, height: 56).background(.white.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                Spacer()
                Label("你的聊天搭子", systemImage: "sparkles").font(.caption.weight(.medium))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("聊得明白，\n回得自然。").font(.system(.largeTitle, design: .rounded).bold())
                Text("一起理清话里的意思，找到适合你的回应。")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white).padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.indigo, Color(red: 0.39, green: 0.29, blue: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }
}

struct MentorMessageEditor: View {
    @Binding var message: AppChatMessage
    let number: Int
    let delete: () -> Void
    let focus: FocusState<Bool>.Binding

    private var accent: Color { message.role == .me ? .indigo : .teal }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("消息 \(number)", systemImage: message.role == .me ? "person.fill" : "person.bubble")
                    .font(.caption.weight(.semibold)).foregroundStyle(accent)
                Spacer()
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash").font(.subheadline)
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("删除第 \(number) 条消息")
            }
            Picker("第 \(number) 条消息的说话人", selection: $message.role) {
                Text("对方说").tag(GoutouChatRole.other)
                Text("我说").tag(GoutouChatRole.me)
            }.pickerStyle(.segmented)
            TextField(message.role == .me ? "你当时是怎么回复的？" : "对方说了什么？输入或粘贴到这里", text: $message.text, axis: .vertical)
                .lineLimit(2...8).focused(focus)
                .accessibilityLabel("第 \(number) 条消息内容")
        }
        .padding(.horizontal, 18).padding(.bottom, 20).padding(.top, 4)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.65))
                .frame(width: 3, height: 32).padding(.leading, 1)
                .accessibilityHidden(true)
        }
    }
}

struct MentorInsightCard: View {
    let title: String
    let text: String
    let icon: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(accent)
            Text(text).font(.body).lineSpacing(5).textSelection(.enabled)
        }.appSurface()
    }
}

struct MentorReplyCard: View {
    let number: Int
    let reply: String
    let isCopied: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(String(format: "%02d", number)).font(.system(.title2, design: .rounded).bold())
                    .foregroundStyle(.indigo)
                Text("推荐回复").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "quote.bubble").foregroundStyle(.indigo.opacity(0.55))
            }
            Text(reply).font(.body).lineSpacing(5).textSelection(.enabled)
            Divider()
            Button(action: copy) {
                Label(isCopied ? "已复制，可以去聊天了" : "复制这条回复", systemImage: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered).tint(isCopied ? .teal : .indigo)
            .accessibilityLabel("\(isCopied ? "已复制" : "复制")第 \(number) 条回复")
        }.appSurface()
    }
}

#Preview("推荐回复 · 虚构示例") {
    ScrollView {
        VStack(spacing: 20) {
            MentorInsightCard(title: "聊天分析", text: "对方主动提出见面，可以顺着话题确认时间和安排。", icon: "sparkles", accent: .indigo)
            MentorReplyCard(number: 1, reply: "好呀，你想吃什么？我们可以一起选一家。", isCopied: false, copy: {})
            MentorReplyCard(number: 2, reply: "可以，周六晚上怎么样？", isCopied: true, copy: {})
        }.padding(20)
    }.background(Color(uiColor: .systemGroupedBackground))
}
