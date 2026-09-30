import CoreGraphics
import Foundation

/// 聊天区域过滤：状态栏 / 标题 / 输入栏 / 键盘这些都不是聊天消息。
///
/// 第一版只做「屏幕中部区域 + 几何规则」的保守过滤，比例全部来自配置。
enum LiveChatViewportFilter {

    /// 用**中心点**判断在不在聊天区域：跨界的行不会被两端同时收进来。
    static func isInsideViewport(_ box: CGRect, config: LiveChatGeometryConfiguration = .default) -> Bool {
        guard box.width > 0, box.height > 0 else { return false }
        let centerY = box.midY
        return centerY > config.topInsetRatio && centerY < (1 - config.bottomInsetRatio)
    }

    static func filter(
        _ observations: [LiveOCRObservation],
        config: LiveChatGeometryConfiguration = .default
    ) -> [LiveOCRObservation] {
        observations.filter { !$0.normalizedText.isEmpty && isInsideViewport($0.box, config: config) }
    }
}

/// 把同一条消息的多行 OCR 合成一个块（微信里一条长消息常被识别成好几行）。
enum LiveChatBlockGrouper {

    /// 阅读顺序：先上后下（左上角坐标系里 y 越小越靠上），同一行从左到右。
    static func readingOrder(
        _ observations: [LiveOCRObservation],
        rowTolerance: CGFloat = 0.012
    ) -> [LiveOCRObservation] {
        observations.sorted { lhs, rhs in
            let lhsRow = (lhs.box.minY / rowTolerance).rounded()
            let rhsRow = (rhs.box.minY / rowTolerance).rounded()
            if lhsRow != rhsRow { return lhsRow < rhsRow }
            return lhs.box.minX < rhs.box.minX
        }
    }

    /// 过滤后的 observations → 按阅读顺序的候选块。
    static func group(
        _ observations: [LiveOCRObservation],
        config: LiveChatGeometryConfiguration = .default,
        timestamp: Date = Date()
    ) -> [LiveChatCandidate] {
        var blocks: [[LiveOCRObservation]] = []
        for observation in readingOrder(observations) where !observation.normalizedText.isEmpty {
            if let last = blocks.last?.last, canMerge(last, observation, config: config) {
                blocks[blocks.count - 1].append(observation)
            } else {
                blocks.append([observation])
            }
        }

        return blocks.map { block in
            let box = union(block)
            let text = join(block)
            return LiveChatCandidate(
                text: text,
                normalizedText: LiveChatText.normalize(text),
                role: LiveChatRoleClassifier.classify(box: box, config: config),
                box: box,
                // 取最低置信度：一条消息里有一行认不准，整条就标低
                confidence: block.map(\.confidence).min() ?? 0,
                timestamp: timestamp
            )
        }
    }

    /// 两行能不能算同一条消息。
    static func canMerge(
        _ previous: LiveOCRObservation,
        _ next: LiveOCRObservation,
        config: LiveChatGeometryConfiguration = .default
    ) -> Bool {
        guard !previous.normalizedText.isEmpty, !next.normalizedText.isEmpty else { return false }

        // 1) 角色必须兼容：一左一右绝不合（「对方：你好 / 我：你好」上下再近也是两条）
        let previousRole = LiveChatRoleClassifier.classify(box: previous.box, config: config)
        let nextRole = LiveChatRoleClassifier.classify(box: next.box, config: config)
        guard rolesCompatible(previousRole, nextRole) else { return false }

        // 2) 垂直间距：太远不算同一条（允许一点点重叠）
        let gap = next.box.minY - previous.box.maxY
        guard gap >= -0.01, gap <= config.lineMergeDistance else { return false }

        // 3) 字号要接近
        let taller = max(previous.box.height, next.box.height)
        let shorter = max(min(previous.box.height, next.box.height), 0.0001)
        guard taller / shorter <= config.lineHeightTolerance else { return false }

        // 4) 水平要有重叠（多行气泡的相邻行通常水平重叠明显）
        return horizontalOverlapRatio(previous.box, next.box) >= config.lineMergeOverlapRatio
    }

    /// me 与 other 绝不合并；unknown 与谁都可能；system 只在 system 之间合并。
    static func rolesCompatible(_ lhs: LiveChatRole, _ rhs: LiveChatRole) -> Bool {
        if lhs == rhs { return true }
        if lhs == .unknown || rhs == .unknown { return true }
        return false
    }

    static func horizontalOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)
        guard overlap > 0 else { return 0 }
        return overlap / max(min(lhs.width, rhs.width), 0.0001)
    }

    static func union(_ block: [LiveOCRObservation]) -> CGRect {
        guard var box = block.first?.box else { return .zero }
        for observation in block.dropFirst() { box = box.union(observation.box) }
        return box
    }

    /// 同一消息的几行拼起来：中日韩直接连，拉丁单词之间补一个空格。
    static func join(_ block: [LiveOCRObservation]) -> String {
        var result = ""
        for observation in block {
            let text = observation.text.trimmed
            guard !text.isEmpty else { continue }
            if result.isEmpty {
                result = text
                continue
            }
            if needsSpace(between: result.last, and: text.first) { result += " " }
            result += text
        }
        return result
    }

    private static func needsSpace(between previous: Character?, and next: Character?) -> Bool {
        guard let previous, let next else { return false }
        return isLatinWordCharacter(previous) && isLatinWordCharacter(next)
    }

    private static func isLatinWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "-")
        }
    }
}
