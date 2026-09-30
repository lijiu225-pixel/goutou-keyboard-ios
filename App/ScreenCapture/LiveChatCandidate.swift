import CoreGraphics
import Foundation

/// 一条消息属于谁。
///
/// `unknown` 是**一级合法状态**：几何看不准就老老实实放这儿，
/// 绝不允许为了凑聊天把它塞进 me / other。
enum LiveChatRole: String, Equatable, CaseIterable {
    case me
    case other
    case unknown
    case system

    var displayName: String {
        switch self {
        case .me: return "我"
        case .other: return "对方"
        case .unknown: return "未确定"
        case .system: return "系统"
        }
    }
}

/// 当前屏幕上的一个聊天消息候选（还没进时间线）。
struct LiveChatCandidate: Equatable {
    /// displayText：Vision 最佳识别的原始文字，展示与未来正文都用它
    let text: String
    /// normalizedText：只用于匹配 / 去重，不用于展示
    let normalizedText: String
    let role: LiveChatRole
    /// 左上角原点、归一化
    let box: CGRect
    let confidence: Double
    let timestamp: Date

    /// 稳定器 / 去重用的指纹：role + 归一化文本（相同文本不同 role 视为不同消息）
    var fingerprint: String { "\(role.rawValue)|\(normalizedText)" }
}

/// 文本归一化与轻量相似度：纯函数、deterministic、可测试，不用 ML。
enum LiveChatText {

    /// 去掉空白与标点符号、统一小写。**只用于匹配**，不会改写 displayText。
    static func normalize(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.symbols.contains(scalar) { continue }
            result.append(scalar)
        }
        return String(result).lowercased()
    }

    /// 归一化编辑距离相似度（0…1）：1 表示完全一样，0 表示完全不像。
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return lhs.isEmpty ? 0 : 1 }
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[right.count]) / Double(max(left.count, right.count))
    }
}
