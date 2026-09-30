import Foundation

/// 阶段 12A 的 OCR 结果：**只放内存**。
///
/// 不落盘、不写 App Group、不进聊天契约、不调用 AI；只为「能不能持续拿到屏幕并认出字」这个目标服务。
struct LiveOCRSnapshot: Equatable {
    let timestamp: Date
    /// 按视觉阅读顺序排好的文本行：先上后下，同一行从左到右。
    let strings: [String]
    /// 上面几行拼起来，给界面直接显示。
    let fullText: String
    /// 结构化结果（阶段 12B 用）：文字 + 置信度 + **左上角原点**的归一化包围盒。
    let observations: [LiveOCRObservation]

    init(timestamp: Date, strings: [String], observations: [LiveOCRObservation] = []) {
        self.timestamp = timestamp
        self.strings = strings
        self.fullText = strings.joined(separator: "\n")
        self.observations = observations
    }
}
