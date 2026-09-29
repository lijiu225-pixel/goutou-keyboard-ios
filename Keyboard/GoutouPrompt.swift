import Foundation

/// 上下文里一段话的归属。
enum GoutouSpeaker: String, Codable {
    case opponent
    case me
    case background

    /// 进 prompt 时用的前缀，沿用 skill 里写死的 `我：…` / `对方：…`。
    var promptLabel: String {
        switch self {
        case .opponent: return "对方"
        case .me: return "我"
        case .background: return "背景"
        }
    }

    var buttonTitle: String {
        switch self {
        case .opponent: return "👤对方"
        case .me: return "🙋我"
        case .background: return "📝背景"
        }
    }
}

struct GoutouSegment: Codable, Equatable {
    let speaker: GoutouSpeaker
    let text: String
}

/// 与 Android / Web 面板同一份口径的 prompt 组装。
///
/// 相对 Android 只改了一处（iOS 面板需要一行判断）：
/// 要求 `relationship` 的**第一句**必须是一句不超过 20 字的判断，
/// 这样 iOS 能只取第一句显示，Android 那边也仍然显示全文、读起来更清楚。
enum GoutouPrompt {

    /// 写死成 Android 面板的两个默认值（iOS 面板不放任务/风格选择器）。
    static let task = "分析她/他说什么意思"
    static let tone = "自然"
    static let headlineLimit = 20
    /// 面板里一次给多少条话术。skill 里写的是 2～3 条，iOS 面板嫌少，这里按 6～8 条要。
    static let minReplies = 6
    static let maxReplies = 8

    static func systemPrompt(skill: String) -> String {
        let contract = """
        仅返回 JSON 对象，不要 Markdown 或代码围栏。字段：meaning（对方可能的意思）、\
        relationship（关系/氛围分析）、replies（\(minReplies)～\(maxReplies) 条可直接发送的中文成品字符串，\
        按推荐顺序排列，**角度要拉开**：几条稳稳接住、几条稍微推进、几条直接问清楚，\
        不要一堆同义改写——这一行覆盖 skill 里写的 2～3 条）、reason（回复理由）。\
        relationship 的第一句必须是一句不超过 \(headlineLimit) 字的判断（例如「对方在试探你会不会主动」），\
        后面再展开依据。无法确定时明确说明。
        """
        return [
            skill.trimmed,
            "当前任务：\(task)。回复风格：\(tone)。",
            contract,
        ].joined(separator: "\n\n")
    }

    /// 把叠加的几段拼成 skill 认得的格式：`对方：…` / `我：…` / `背景：…`。
    /// `memory` 是长期档案，会以单独一段放在对话前面（每次分析都带上）。
    /// `extraRequirement` 会附在最后——离答案最近的一句，模型最听。
    static func userMessage(
        segments: [GoutouSegment],
        memory: [String] = [],
        extraRequirement: String? = nil
    ) -> String {
        let body = segments
            .map { "\($0.speaker.promptLabel)：\($0.text.trimmed)" }
            .filter { $0.count > 3 }
            .joined(separator: "\n")
        let archive = memory
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
        var sections: [String] = []
        if !archive.isEmpty {
            let archiveText = archive.map { "- \($0)" }.joined(separator: "\n")
            sections.append("长期档案（用户自己提供的背景事实，不是本次对话）：\n\(archiveText)")
        }
        sections.append("聊天内容：\n\(body)")
        if let extraRequirement = extraRequirement, !extraRequirement.trimmed.isEmpty {
            sections.append(extraRequirement.trimmed)
        }
        return sections.joined(separator: "\n\n")
    }

    /// 主分析用的那句"再强调一次"——放在最后，模型才真的会给够条数。
    static var replyRequirement: String {
        "本次要求：replies 给 \(minReplies)～\(maxReplies) 条可直接发送的成品，角度拉开；不要把候选压到 2～3 条。"
    }

    /// 只取 relationship 的第一句，超过 20 字就截断加省略号。
    static func headline(fromRelationship text: String) -> String {
        let flattened = text.trimmed.replacingOccurrences(of: "\n", with: " ")
        guard !flattened.isEmpty else { return "" }

        var sentence = flattened
        for mark in ["。", "！", "？", "；", "!", "?", ";", "."] {
            guard let range = flattened.range(of: mark) else { continue }
            let candidate = String(flattened[flattened.startIndex..<range.upperBound]).trimmed
            if !candidate.isEmpty, candidate.count < sentence.count {
                sentence = candidate
            }
        }

        if sentence.count <= headlineLimit { return sentence }
        return String(sentence.prefix(headlineLimit)) + "…"
    }
}
