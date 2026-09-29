import Foundation

/// 从「本次聊天」里归纳值得长期保留的事实/近况，并和这个人已有的记忆比对。
///
/// 三条硬规矩：
/// 1. **不保存聊天原文**——只产出候选（说到底就是几句话），原文该丢就丢；
/// 2. **不删除**——只允许 ADD / UPDATE / MERGE / IGNORE；
/// 3. 只认当前人物的记忆，目标 id 会再校验一次归属。
///
/// 网络层没动：请求仍然由 `GoutouAIClient.buildURLRequest` 组装（同一套鉴权/超时），
/// 解析也复用它的宽容 JSON 工具。
enum GoutouMemoryExtractor {

    static let maxCandidates = 8

    static func systemPrompt(existing: [PersonMemory]) -> String {
        let known = existing.isEmpty
            ? "（现在还没有任何记忆）"
            : existing.map { "- id=\($0.id.uuidString) [\($0.category.label)] \($0.content)" }.joined(separator: "\n")
        let contract = """
        只返回一个 JSON 对象，不要 Markdown、不要解释。格式：
        {"operations":[{"op":"ADD|UPDATE|MERGE|IGNORE","targetID":null,"content":"...","category":"stable_fact","importance":3,"confidence":0.8}]}

        规则：
        - 只从这段聊天里**能直接看出来的**东西提炼，不要脑补、不要编。
        - **不要保存聊天原文、不要逐句抄**；content 写成一句独立、完整、以后单独看也懂的中文。
        - category 只能是这几个之一：stable_fact（稳定事实）、preference（偏好）、relationship（关系）、communication_style（沟通习惯）、important_event（重要事件）、recent_status（近期状态，会过期的用这个）。
        - 和已有记忆说的是同一件事 → 用 UPDATE（内容需要改写）或 MERGE（补充新细节），targetID 填已有那条的 id；只是又被确认了一次 → IGNORE。
        - 真正的新信息 → ADD。**不要**为同一件事反复 ADD 近义重复的条目。
        - 不允许删除：不要输出任何删除操作。
        - 最多 \(maxCandidates) 条；这段聊天里没有值得长期记的东西就返回 {"operations":[]}。
        """
        return """
        \(contract)

        这个人已有的记忆：
        \(known)
        """
    }

    static func userMessage(segments: [GoutouSegment]) -> String {
        GoutouPrompt.userMessage(segments: segments)
    }

    /// 解析提取结果。JSON 读不懂 → nil（调用方就什么都不做）；读懂了但为空 → 空数组（记忆不动）。
    static func parse(_ text: String) -> [GoutouMemoryCandidate]? {
        guard let payload = GoutouAIClient.decodePayload(text) else { return nil }
        let raw = (payload["operations"] as? [Any]) ?? (payload["memories"] as? [Any]) ?? []
        var candidates: [GoutouMemoryCandidate] = []

        for item in raw {
            guard let dict = item as? [String: Any] else { continue }
            let opText = ((dict["op"] as? String) ?? (dict["operation"] as? String) ?? "ADD").uppercased()
            guard let operation = GoutouMemoryOperation(rawValue: opText) else { continue }

            let content = ((dict["content"] as? String) ?? (dict["text"] as? String) ?? "").trimmed
            let category = MemoryCategory.from((dict["category"] as? String) ?? "")
            let importance = (dict["importance"] as? Int) ?? (dict["importance"] as? Double).map { Int($0) } ?? 3
            let confidence = (dict["confidence"] as? Double) ?? (dict["confidence"] as? Int).map { Double($0) } ?? 0.7
            let targetText = ((dict["targetID"] as? String) ?? (dict["target_id"] as? String) ?? "").trimmed
            let targetID = UUID(uuidString: targetText)

            switch operation {
            case .add:
                guard !content.isEmpty else { continue }
            case .update, .merge:
                // 没给目标 = 这条不合法，丢掉（绝不当成 ADD 用）
                guard targetID != nil, !content.isEmpty else { continue }
            case .ignore:
                break
            }

            candidates.append(GoutouMemoryCandidate(
                operation: operation,
                targetID: targetID,
                content: content,
                category: category,
                importance: GoutouMemoryApplier.clampImportance(importance),
                confidence: GoutouMemoryApplier.clampConfidence(confidence)
            ))
            if candidates.count >= maxCandidates { break }
        }
        return candidates
    }

    /// 跑一次提取。任何失败（请求错、超时、JSON 不合法）都回调 nil —— 调用方据此**不动记忆**。
    static func extract(
        config: GoutouConfig,
        existing: [PersonMemory],
        segments: [GoutouSegment],
        completion: @escaping ([GoutouMemoryCandidate]?) -> Void
    ) {
        let request: URLRequest
        do {
            request = try GoutouAIClient.buildURLRequest(
                config: config,
                systemPrompt: systemPrompt(existing: existing),
                userMessage: userMessage(segments: segments)
            )
        } catch {
            completion(nil)
            return
        }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = GoutouAIClient.timeout
        sessionConfig.timeoutIntervalForResource = GoutouAIClient.timeout
        sessionConfig.waitsForConnectivity = false
        let session = URLSession(configuration: sessionConfig)

        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard
                error == nil,
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode),
                let data = data,
                let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let choices = root["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any]
            else {
                completion(nil)
                return
            }
            let text = GoutouAIClient.stripThinking(GoutouAIClient.extractText(from: message)).trimmed
            completion(parse(text))
        }.resume()
    }
}
