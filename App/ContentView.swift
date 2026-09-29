import SwiftUI

/// 宿主 App 只做两件事：告诉用户怎么把键盘加到系统里，以及给一个能马上试打的输入框。
struct ContentView: View {
    @State private var draft: String = ""

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 110)
                        .overlay(alignment: .topLeading) {
                            if draft.isEmpty {
                                Text("点这里，切到「狗头军师」键盘试打几个字母")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("自测输入框")
                } footer: {
                    Text("点输入框 → 长按左下角 🌐 → 选「狗头军师」。")
                }

                Section("把键盘加到系统里") {
                    StepRow(index: 1, text: "设置 → 通用 → 键盘 → 键盘 → 添加新键盘")
                    StepRow(index: 2, text: "在「第三方键盘」里选「狗头军师」")
                    StepRow(index: 3, text: "回到任意输入框，长按 🌐 切过去即可使用")
                }

                Section("关于") {
                    LabeledContent("版本", value: "v\(version) (build \(buildNumber))")
                    LabeledContent("输入内容", value: "只在本机处理，不联网不上传")
                }
            }
            .navigationTitle("狗头军师输入法")
        }
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
