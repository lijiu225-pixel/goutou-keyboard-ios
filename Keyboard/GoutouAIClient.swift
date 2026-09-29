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
    case badJSON

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
        case .badJSON:
            return "接口返回的不是约定格式的 JSON"
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
            throw GoutouAIError.badJSON
        }
        if let error = root["error"] as? [String: Any] {
            let detail = (error["message"] as? String) ?? (error["code"] as? String) ?? ""
            throw GoutouAIError.http(0, detail)
        }
        guard
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw GoutouAIError.empty
        }

        let text = stripCodeFence(content.trimmed)
        guard !text.isEmpty else { throw GoutouAIError.empty }
        guard let payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw GoutouAIError.badJSON
        }

        let relationship = (payload["relationship"] as? String) ?? ""
        let replies = (payload["replies"] as? [Any] ?? [])
            .compactMap { item -> String? in
                if let text = item as? String { return text.trimmed }
                if let dict = item as? [String: Any], let text = dict["text"] as? String { return text.trimmed }
                return nil
            }
            .filter { !$0.isEmpty }

        let headline = GoutouPrompt.headline(fromRelationship: relationship)
        guard !headline.isEmpty || !replies.isEmpty else { throw GoutouAIError.empty }
        return GoutouResult(headline: headline, replies: Array(replies.prefix(GoutouPrompt.maxReplies)))
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
                completion(.failure(.badJSON))
            }
        }
        task.resume()
        return task
    }
}
