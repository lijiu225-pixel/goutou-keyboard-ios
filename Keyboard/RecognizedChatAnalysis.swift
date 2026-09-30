import Foundation

/// 阶段 9 / 10：把「正在使用的识别聊天」交给现有 AI 网络层分析。
///
/// 用户点「分析这段聊天」→ 一次请求 → 聊天分析 + 对方状态 + 恰好 3 条推荐回复。
/// 三条回复本阶段只展示：不插入输入框、不自动发送、不写人物记忆、不落盘。
/// 本文件纯 Foundation、不联网：网络由控制器调用现有 `GoutouAIClient` 完成。

/// 阶段 10 的正式结果：一份聊天分析 + 对方当前状态 + **恰好 3 条**候选回复。
///
/// 和旧 manual 狗头军师的 `GoutouResult`（headline + 6～8 条）是两个东西，
/// 那条链路一个字都没动，避免语义混淆。
struct RecognizedChatResult: Equatable {
    let analysis: String
    let tone: String
    let replies: [String]

    /// 正式要求：恰好 3 条。
    static let requiredReplies = 3
    /// 单条候选的长度上限：超了截断加省略号，不让模型塞几千字当一条"回复"。
    static let maxReplyLength = 300
    /// 对方状态一句话的长度上限。
    static let maxToneLength = 200
    static let ellipsis = "…"

    /// 宽容进、严格出：把拆出来的字段归一化成 analysis + tone + 恰好 3 条。
    ///
    /// - trim 每条回复；
    /// - 丢掉空白与纯标点的；
    /// - 丢掉与前面完全重复的；
    /// - 单条超长截断；
    /// - 不足 3 条有效回复就失败，不用空串凑数、不复制同一条。
    static func normalized(
        _ fields: GoutouAIClient.RecognizedChatFields
    ) -> Result<RecognizedChatResult, RecognizedChatAnalysisError> {
        let analysis = capped(fields.analysis, limit: GoutouAIClient.maxAnalysisLength)
        let tone = capped(fields.tone, limit: maxToneLength)
        guard !analysis.isEmpty, !tone.isEmpty else { return .failure(.incompleteResult) }

        var replies: [String] = []
        for raw in fields.replies {
            let text = capped(raw, limit: maxReplyLength)
            guard !text.isEmpty, hasVisibleContent(text) else { continue }
            guard !replies.contains(text) else { continue }
            replies.append(text)
        }
        guard replies.count >= requiredReplies else {
            return .failure(.notEnoughReplies(validCount: replies.count))
        }
        return .success(RecognizedChatResult(
            analysis: analysis,
            tone: tone,
            replies: Array(replies.prefix(requiredReplies))
        ))
    }

    private static func capped(_ text: String?, limit: Int) -> String {
        guard let text = text else { return "" }
        let flat = text.trimmed
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + ellipsis
    }

    /// 纯空白 / 纯标点 / 只有一个表情的候选不算有效回复。
    private static func hasVisibleContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}

/// 分析请求的失败原因。文案给人看，不回显模型原文、API Key 或沙盒路径。
enum RecognizedChatAnalysisError: Error, Equatable {
    /// 没有正在使用的识别聊天（预览不算）
    case noActiveContext
    case noFullAccess
    case notConfigured
    /// 军师人格没打进包
    case missingSkill
    /// 上一次请求还没回来
    case alreadyRunning
    case ai(GoutouAIError)
    /// 阶段 10：缺聊天分析或对方状态
    case incompleteResult
    /// 阶段 10：归一化之后不足 3 条有效回复
    case notEnoughReplies(validCount: Int)

    var message: String {
        switch self {
        case .noActiveContext:
            return "还没有正在使用的识别聊天，先在预览里点「使用这份聊天」。"
        case .noFullAccess:
            return "请先为狗头军师键盘开启完全访问，再分析聊天。"
        case .notConfigured:
            return "还没配置 AI 接口（Base URL / Model）。"
        case .missingSkill:
            return "军师人格没打进包，需要重新构建一次。"
        case .alreadyRunning:
            return "上一次分析还在进行中。"
        case .incompleteResult:
            return "分析结果不完整（缺少聊天分析或对方状态），请重新分析。"
        case .notEnoughReplies(let validCount):
            return "分析结果里只有 \(validCount) 条可用回复（需要 \(RecognizedChatResult.requiredReplies) 条），请重新分析。"
        case .ai(let error):
            return RecognizedChatAnalysisError.friendly(error)
        }
    }

    /// 网络错误只说人话；HTTP 只给状态码，不吐服务器原文。
    private static func friendly(_ error: GoutouAIError) -> String {
        switch error {
        case .notConfigured:
            return "还没配置 AI 接口（Base URL / Model）。"
        case .badURL:
            return "Base URL 不合法，要带 http(s):// 的完整地址。"
        case .timeout:
            return "分析失败：等太久了（超时 \(Int(GoutouAIClient.timeout)) 秒）。"
        case .network:
            return "分析失败：网络没通，检查网络后重试。"
        case .http(let code, _):
            if code == 401 || code == 403 {
                return "接口返回 HTTP \(code)：多半是 API Key 没配对。"
            }
            if code == 0 {
                return "分析失败：接口返回了错误。"
            }
            return "接口返回 HTTP \(code)。"
        case .empty:
            return "分析失败：接口没给内容。"
        case .badJSON:
            return "分析失败：返回的不是约定格式。"
        case .reasoningOnly:
            return "分析失败：模型只回了思考、没有正文。"
        case .truncated:
            return "分析失败：模型输出被截断。"
        }
    }
}

/// 分析区只允许出现这四种状态，旧结果不会和新加载混在一起。
enum RecognizedChatAnalysisState: Equatable {
    case idle
    case loading
    case success(RecognizedChatResult)
    case failure(RecognizedChatAnalysisError)
}

/// `begin` 的结果：要么拿到了本次请求的代际号，要么被挡下来。
enum RecognizedChatAnalysisStart: Equatable {
    case started(generation: Int)
    case blocked(RecognizedChatAnalysisError)
}

/// 「分析这段聊天」的状态机。
///
/// 所有准入判断都在这儿（完全访问、配置、人格、有没有 Active Context、是不是正在跑），
/// UI 只负责显示 `state` 和把点击转成 `begin`。请求由控制器用现有 AI 网络层发出，
/// 回来时带代际号交给 `complete`——代际号对不上就一个字都不写，
/// 所以「A 还在路上时用户读了 B」不会让 A 的结果复活。
struct RecognizedChatAnalysisSession: Equatable {
    private(set) var state: RecognizedChatAnalysisState = .idle
    private(set) var generation = 0

    var isAnalyzing: Bool { state == .loading }

    mutating func begin(
        hasFullAccess: Bool,
        config: GoutouConfig?,
        skillAvailable: Bool,
        context: RecognizedChatContext?
    ) -> RecognizedChatAnalysisStart {
        // 正在跑就原样返回：不动状态、不发第二次请求。
        if isAnalyzing { return .blocked(.alreadyRunning) }

        guard hasFullAccess else {
            state = .failure(.noFullAccess)
            return .blocked(.noFullAccess)
        }
        guard config?.isReady == true else {
            state = .failure(.notConfigured)
            return .blocked(.notConfigured)
        }
        guard skillAvailable else {
            state = .failure(.missingSkill)
            return .blocked(.missingSkill)
        }
        // 预览不算：只有用户点过「使用这份聊天」的上下文才能分析。
        guard let context = context, !context.messages.isEmpty else {
            state = .failure(.noActiveContext)
            return .blocked(.noActiveContext)
        }

        generation += 1
        state = .loading
        return .started(generation: generation)
    }

    /// 请求回来了。代际号对不上（用户已经读了别的聊天、取消了使用或收起过面板）就直接丢掉。
    mutating func complete(generation: Int, result: Result<RecognizedChatResult, RecognizedChatAnalysisError>) {
        guard generation == self.generation else { return }
        switch result {
        case .success(let value):
            // 再兜一层，而且和归一化共用同一套规则：手写或脏值同样进不了 success。
            switch RecognizedChatResult.normalized(GoutouAIClient.RecognizedChatFields(
                analysis: value.analysis,
                tone: value.tone,
                replies: value.replies
            )) {
            case .success(let cleaned):
                state = .success(cleaned)
            case .failure(let error):
                state = .failure(error)
            }
        case .failure(let error):
            state = .failure(error)
        }
    }

    /// 上下文变了（读到新聊天 / 取消使用 / 读取失败）：清结果，并让在途请求作废。
    mutating func invalidate() {
        generation += 1
        state = .idle
    }

    /// 面板收起或键盘被系统收起：作废在途请求，但已经拿到的分析留着。
    mutating func cancelInFlight() {
        generation += 1
        if state == .loading { state = .idle }
    }
}

extension RecognizedChatAnalysisSession {
    /// 阶段 11：这条回复现在能不能插进宿主输入框。
    ///
    /// 只有「**当前**结果里逐字有这一条」才返回它——idle / loading / failure / 已经失效的旧结果
    /// 一律返回 nil。返回的就是要写进输入框的原文：不加序号、不加空格、不加换行。
    func replyToInsert(_ reply: String) -> String? {
        guard case .success(let result) = state else { return nil }
        guard result.replies.contains(reply) else { return nil }
        return reply
    }
}

/// 阶段 11：把一条候选回复写进宿主输入框。
///
/// 只做一件事：确认这条回复属于**当前**结果，然后原样写一次。
/// 写入方式由调用方注入（生产环境就是 `textDocumentProxy.insertText`），
/// 这里不清草稿、不加空格、不加换行、不模拟回车、不发送、不联网、不写记忆、不落盘。
enum RecognizedReplyInsert {
    @discardableResult
    static func perform(
        _ reply: String,
        from session: RecognizedChatAnalysisSession,
        write: (String) -> Void
    ) -> Bool {
        guard let text = session.replyToInsert(reply) else { return false }
        write(text)
        return true
    }
}

/// 阶段 9 专用的 Prompt：只做聊天分析。
///
/// 旧的 `GoutouPrompt.systemPrompt(skill:)`（军师人格 + 6～8 条话术契约）一个字都没动，
/// 手动上下文分析、推荐回复、记忆链路继续用它；这里只给「识别聊天分析」这一条链路用。
enum RecognizedChatPrompt {

    /// 追加在 skill 后面的阶段 10 正式契约：覆盖上面任何关于候选话术、回复条数的要求。
    /// 正式要求恰好 3 条回复，不是旧 manual 链路的 6～8 条。
    static let analysisContract = """
    阶段 10 正式结果（覆盖上面任何关于候选话术、回复条数的要求）：
    - 只分析这一段聊天，不要重新判断谁是谁。
    - 「我」代表输入法用户本人，「对方」代表聊天对象，归属已经由用户人工确认。
    - 保持原始消息顺序，不要改写正文。
    - 分析当前聊天的氛围和关键含义。
    - 判断对方当前语气 / 态度 / 意图。
    - 给出恰好 3 条可以直接回复的候选话术，三条要有区别（一条自然稳妥、一条稍微主动推进、一条轻松一点），不要只是换几个字。
    - 不写人设记忆、人物档案或长期记忆。
    - 只返回 JSON 对象，不要 Markdown 或代码围栏，格式：
    {"analysis": "聊天分析正文", "tone": "对方语气 / 态度 / 意图", "replies": ["回复一", "回复二", "回复三"]}
    """

    static func systemPrompt(skill: String) -> String {
        [skill.trimmed, analysisContract].joined(separator: "\n\n")
    }

    /// 把结构化消息按原顺序摊成 `我：…` / `对方：…`。角色和正文一个字都不改，也不重新猜归属。
    /// 超出剪贴板契约上限（条数 / 单条 / 总长）时返回 nil——不截断、不 force unwrap。
    static func userMessage(messages: [GoutouChatClipboardMessage]) -> String? {
        guard !messages.isEmpty, messages.count <= GoutouChatClipboardCodec.maxMessages else { return nil }
        var lines: [String] = []
        for message in messages {
            let text = message.text.trimmed
            guard !text.isEmpty, text.count <= GoutouChatClipboardCodec.maxMessageLength else { return nil }
            lines.append("\(message.role.displayName)：\(text)")
        }
        let body = lines.joined(separator: "\n")
        guard body.count <= GoutouChatClipboardCodec.maxEncodedLength else { return nil }
        return """
        下面是一段已经人工确认过归属的聊天记录。「我」是输入法用户本人，「对方」是聊天对象，\
        角色与顺序已经确认，不要重新判断或改写。

        聊天内容：
        \(body)

        本次要求：分析这段聊天，判断对方当前语气 / 态度 / 意图，并给出恰好 \(RecognizedChatResult.requiredReplies) 条可直接回复的候选话术。
        """
    }
}
