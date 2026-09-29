import Foundation

/// 军师接口配置：Base URL / Model / Key。
///
/// - 存哪里：**键盘扩展自己的 UserDefaults**（不走 App Group，免费账号也能用）。
/// - 在哪里填：宿主 App 的表单（那里能用系统键盘、能粘贴），点「复制配置」，
///   回键盘 ⚙ 面板点「从剪贴板导入」。key 全程只在这台手机上，不进仓库。
struct GoutouConfig: Codable, Equatable {
    var baseURL: String
    var model: String
    var apiKey: String

    static let storageKey = "goutou.ai.config"
    /// 导出文本的第一行，导入时用它认领剪贴板里的内容，避免误吃别的文本。
    static let marker = "GOUTOU-AI/1"

    static let empty = GoutouConfig(baseURL: "", model: "", apiKey: "")

    var isReady: Bool {
        !baseURL.trimmed.isEmpty && !model.trimmed.isEmpty
    }

    /// 真正请求的地址：允许直接填完整的 `/chat/completions`，也允许只填到 `/v1`。
    var chatCompletionsURL: URL? {
        var text = baseURL.trimmed
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        if !text.lowercased().hasSuffix("/chat/completions") {
            text += "/chat/completions"
        }
        // iOS 17 的 URL(string:) 很宽松，连「不是网址」都能建出相对 URL，
        // 所以这里必须自己把住：要有 http/https，还要有主机名。
        guard let url = URL(string: text) else { return nil }
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    /// 界面上显示用，key 只露最后 4 位。
    var summary: String {
        let masked: String
        if apiKey.isEmpty {
            masked = "未填 key"
        } else if apiKey.count <= 4 {
            masked = "****"
        } else {
            masked = "****" + String(apiKey.suffix(4))
        }
        return "\(model.trimmed.isEmpty ? "未填模型" : model.trimmed) · \(masked)"
    }

    // MARK: - 导出 / 导入（宿主 App → 剪贴板 → 键盘）

    var exportText: String {
        [
            Self.marker,
            "base=\(baseURL.trimmed)",
            "model=\(model.trimmed)",
            "key=\(apiKey.trimmed)",
        ].joined(separator: "\n")
    }

    /// 解析不出来就返回 nil —— 剪贴板里是别的东西时不能瞎存。
    static func parse(importText: String) -> GoutouConfig? {
        let lines = importText.split(separator: "\n", omittingEmptySubsequences: false)
        guard let head = lines.first.map({ String($0).trimmed }), head == marker else { return nil }

        var config = GoutouConfig.empty
        for line in lines.dropFirst() {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmed
            let value = String(parts[1]).trimmed
            switch key {
            case "base": config.baseURL = value
            case "model": config.model = value
            case "key": config.apiKey = value
            default: break
            }
        }
        return config.isReady ? config : nil
    }

    // MARK: - 存取

    static func load(from defaults: UserDefaults = .standard) -> GoutouConfig? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(GoutouConfig.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
