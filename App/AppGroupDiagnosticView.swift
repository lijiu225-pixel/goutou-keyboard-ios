import SwiftUI

struct AppGroupDiagnosticView: View {
    @State private var status = "尚未写入"
    @State private var timestamp = "—"
    @State private var containerAvailable = false
    private let diagnostics = AppGroupDiagnostics()

    var body: some View {
        Form {
            Section {
                LabeledContent("App Group ID", value: SharedConstants.appGroupID)
                LabeledContent("共享容器", value: containerAvailable ? "可用" : "不可用")
                LabeledContent("测试文件", value: SharedConstants.probeFilename)
                Text(status)
                Text("最近写入时间：\(timestamp)")
                    .textSelection(.enabled)
                Button("写入测试数据") {
                    containerAvailable = diagnostics.sharedContainerURL() != nil
                    do {
                        let probe = try diagnostics.writeProbe()
                        timestamp = probe.timestamp
                        status = "主 App 写入成功；去键盘「军师 → 设置 → 读取 App Group 测试」核对时间。"
                    } catch { status = error.localizedDescription }
                }
            } header: { Text("通信测试") }
            footer: {
                Text("本页只写固定测试文字，不写聊天。当前组由签名服务提供；真机通信验证通过后，再确认组的使用范围并接入聊天共享。")
            }
        }
        .navigationTitle("App Group 诊断")
        .onAppear { containerAvailable = diagnostics.sharedContainerURL() != nil }
    }
}
