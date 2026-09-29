import Foundation

/// 军师返回给面板的东西。
struct GoutouResult: Equatable {
    /// relationship 的第一句，≤20 字。
    let headline: String
    /// 2～3 条可直接发送的话术。
    let replies: [String]
}

enum GoutouAIError: Error, Equatable {
    case notConfigured
    case badURL
    case timeout
    case network(String)
    case http(Int, String)
    case empty
    /// 返回的内容不是约定 JSON；带上开头一小段，方便定位到底是什么
    case badJSON(String)
    /// 只回了思考（reasoning），没有正文；参数表示是不是被 max_tokens 截断了
    case reasoningOnly(Bool)

    var message: String {
        switch self {
        case .notConfigured:
            return "还没配置 AI 接口"
        case .badURL:
            return "Base URL 不合法，要带 https:// 那种完整地址"
        case .timeout:
            return "请求超时（\(Int(GoutouAIClient.timeout)) 秒）"
        case .network(let detail):
            return "网络请求失败：\(detail)"
        case .http(let code, let detail):
            return "接口返回 HTTP \(code)\(detail.isEmpty ? "" : "：\(detail)")"
        case .empty:
            return "接口返回的是空内容"
        case .badJSON(let snippet):
            return snippet.isEmpty
                ? "接口返回的不是约定格式的 JSON"
                : "接口返回的不是约定格式的 JSON（开头是：\(snippet)）"
        case .reasoningOnly(let truncated):
            return truncated
                ? "模型把 token 都花在思考上了，正文被截断。换成非推理模型，或把上下文缩短再试"
                : "模型只返回了思考内容，没有正文。换成非推理模型再试"
        }
    }
}

/// OpenAI 兼容 `chat/completions` 的最小客户端。
///
/// 纯 Foundation，不碰 UIKit —— 这样 CI 上 `swiftc` 能直接把它编进冒烟测试，
/// 连请求体长什么样都能在 macOS 上验，不用真机、不用模拟器。
enum GoutouAIClient {

    static let timeout: TimeInterval = 60
    static let temperature = 0.6
    /// 与 Android 面板一致：推理模型会把思考也算进这个预算，给小了可能只剩思考没有正文。
    static let maxTokens = 4096

    // MARK: - 请求

    static func buildURLRequest(
        config: GoutouConfig,
        systemPrompt: String,
        userMessage: String
    ) throws -> URLRequest {
        guard config.isReady else { throw GoutouAIError.notConfigured }
        guard let url = config.chatCompletionsURL else { throw GoutouAIError.badURL }
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else { throw GoutouAIError.badURL }

        let body: [String: Any] = [
            "model": config.model.trimmed,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage],
            ],
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !config.apiKey.trimmed.isEmpty {
            request.setValue("Bearer \(config.apiKey.trimmed)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - 响应

    static func parseResponse(data: Data) throws -> GoutouResult {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GoutouAIError.badJSON(snippet(String(data: data, encoding: .utf8) ?? ""))
        }
        if let error = root["error"] as? [String: Any] {
            let detail = (error["message"] as? String) ?? (error["code"] as? String) ?? ""
            throw GoutouAIError.http(0, detail)
        }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else {
            throw GoutouAIError.empty
        }
        guard let message = first["message"] as? [String: Any] else { throw GoutouAIError.empty }
        let truncated = (first["finish_reason"] as? String) == "length"

        // content 可能是字符串，也可能是 [{"type":"text","text":"…"}] 这种分片
        let text = stripThinking(extractText(from: message)).trimmed
        if text.isEmpty {
            let reasoning = (message["reasoning_content"] as? String) ?? (message["reasoning"] as? String) ?? ""
            if !reasoning.trimmed.isEmpty {
                throw GoutouAIError.reasoningOnly(truncated)
            }
            throw GoutouAIError.empty
        }

        guard let payload = decodePayload(text) else {
            throw GoutouAIError.badJSON(snippet(text))
        }

        let unwrapped = unwrapPayload(payload)
        let relationship = firstString(
            in: unwrapped,
            keys: ["relationship", "关系", "关系分析", "关系与氛围", "headline", "判断", "总结"]
        ) ?? ""
        let replies = normalizedReplies(from: unwrapped)

        let headline = GoutouPrompt.headline(fromRelationship: relationship)
        guard !headline.isEmpty || !replies.isEmpty else { throw GoutouAIError.empty }
        return GoutouResult(headline: headline, replies: Array(replies.prefix(GoutouPrompt.maxReplies)))
    }

    // MARK: - 宽容解析

    /// `content` 取字符串；数组形式（OpenAI 新格式）把 text 片段拼起来。
    static func extractText(from message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    /// 去掉 ` thinking…<｜end▁of▁thinking｜>`、`<thinking>`、`【思考】…` 这类推理片段。
    static func stripThinking(_ text: String) -> String {
        var result = text
        let pairs = [
            ("thinking", "thinking"),
            ("think", "think"),
            ("reasoning", "reasoning"),
        ]
        for (open, close) in pairs {
            while let start = result.range(of: "<\(open)>"), let end = result.range(of: "</\(close)>", range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        return result
    }

    /// 从模型返回里挖出那个约定 JSON。故意做得很宽：
    /// 直接就是 JSON / 包在代码围栏里 / 前后有废话 / 尾逗号 / 外面又套了一层。
    static func decodePayload(_ text: String) -> [String: Any]? {
        if let object = jsonObject(text) { return object }

        let unfenced = stripCodeFence(text)
        if unfenced != text, let object = jsonObject(unfenced) { return object }

        for candidate in jsonCandidates(in: unfenced) {
            if let object = jsonObject(candidate) { return object }
            let repaired = repairTrailingCommas(candidate)
            if repaired != candidate, let object = jsonObject(repaired) { return object }
        }
        return nil
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmed
        guard trimmed.hasPrefix("{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
    }

    /// 抠出正文里每一个「括号配平」的 JSON 对象（按出现顺序）。
    static func jsonCandidates(in text: String, limit: Int = 3) -> [String] {
        var results: [String] = []
        let characters = Array(text)
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false

        for (index, character) in characters.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                if depth > 0 { inString = true }
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let begin = start {
                    results.append(String(characters[begin...index]))
                    if results.count >= limit { return results }
                    start = nil
                }
            default:
                break
            }
        }
        return results
    }

    /// 只补最常见的坏 JSON：对象/数组尾部的多余逗号。
    static func repairTrailingCommas(_ text: String) -> String {
        var result = ""
        let characters = Array(text)
        var inString = false
        var escaped = false

        for (index, character) in characters.enumerated() {
            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
                result.append(character)
                continue
            }
            if character == "," {
                let rest = characters[(index + 1)...]
                let nextMeaningful = rest.first { !$0.isWhitespace }
                if nextMeaningful == "}" || nextMeaningful == "]" {
                    continue    // 丢掉尾逗号
                }
            }
            result.append(character)
        }
        return result
    }

    /// 有些中转会把结果再包一层：`{"data": {...}}` / `{"result": {...}}`。
    static func unwrapPayload(_ payload: [String: Any]) -> [String: Any] {
        let wrappers = ["data", "result", "output", "answer", "json"]
        for key in wrappers {
            if let nested = payload[key] as? [String: Any],
               nested["relationship"] != nil || nested["replies"] != nil || nested["关系"] != nil {
                return nested
            }
        }
        return payload
    }

    static func firstString(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.trimmed.isEmpty { return value }
            if let value = payload[key] as? [String], let first = value.first { return first }
        }
        return nil
    }

    /// `replies` 可能是数组、数组里套对象、也可能是换行分隔的一整段。
    static func normalizedReplies(from payload: [String: Any]) -> [String] {
        let keys = ["replies", "reply", "回复", "话术", "候选", "suggestions", "responses"]
        for key in keys {
            guard let value = payload[key] else { continue }
            if let text = value as? String {
                return text
                    .split(whereSeparator: { $0 == "\n" || $0 == "；" })
                    .map { String($0).trimmed }
                    .filter { !$0.isEmpty }
            }
            if let items = value as? [Any] {
                return items.compactMap { item -> String? in
                    if let text = item as? String { return text.trimmed }
                    if let dict = item as? [String: Any] {
                        return firstString(in: dict, keys: ["text", "content", "reply", "回复", "话术"])?.trimmed
                    }
                    return nil
                }.filter { !$0.isEmpty }
            }
        }
        return []
    }

    /// 错误信息里带一小段原文（换行压平、最多 40 字）。
    static func snippet(_ text: String, limit: Int = 40) -> String {
        let flattened = text.trimmed.replacingOccurrences(of: "\n", with: " ")
        return String(flattened.prefix(limit))
    }

    static func stripCodeFence(_ text: String) -> String {
        var result = text.trimmed
        if result.hasPrefix("```") {
            if let firstBreak = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: firstBreak)...])
            }
            if let fence = result.range(of: "```", options: .backwards) {
                result = String(result[result.startIndex..<fence.lowerBound])
            }
            result = result.trimmed
        }
        return result
    }

    // MARK: - 发送（60 秒超时，可取消）

    @discardableResult
    static func analyze(
        config: GoutouConfig,
        systemPrompt: String,
        userMessage: String,
        completion: @escaping (Result<GoutouResult, GoutouAIError>) -> Void
    ) -> URLSessionTask? {
        let request: URLRequest
        do {
            request = try buildURLRequest(config: config, systemPrompt: systemPrompt, userMessage: userMessage)
        } catch let error as GoutouAIError {
            completion(.failure(error))
            return nil
        } catch {
            completion(.failure(.badURL))
            return nil
        }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout
        sessionConfig.waitsForConnectivity = false
        let session = URLSession(configuration: sessionConfig)

        let task = session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }

            if let error = error as NSError? {
                if error.domain == NSURLErrorDomain, error.code == NSURLErrorTimedOut {
                    completion(.failure(.timeout))
                } else if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
                    completion(.failure(.network("已取消")))
                } else {
                    completion(.failure(.network(error.localizedDescription)))
                }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.network("没有收到响应")))
                return
            }
            let body = data ?? Data()
            guard (200...299).contains(http.statusCode) else {
                let detail = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                let errorObject = detail?["error"] as? [String: Any]
                let message = (errorObject?["message"] as? String) ?? ""
                completion(.failure(.http(http.statusCode, message)))
                return
            }
            do {
                completion(.success(try parseResponse(data: body)))
            } catch let error as GoutouAIError {
                completion(.failure(error))
            } catch {
                completion(.failure(.badJSON("")))
            }
        }
        task.resume()
        return task
    }
}
