import CoreFoundation
import Foundation

// MARK: - 剪贴板契约的角色
//
// 和 `ChatSnapshot.swift` 里的 `ChatRole` 是两个东西，故意不复用：
// `ChatRole` 是 App Group 缓存用的宽口径（还有 system / unknown），
// 这里是**剪贴板契约**的窄口径 —— 只认 me / other，多一个字都算格式错误。
// 屏幕识别出的「未确定」不允许写进剪贴板，必须在 App 里人工定完再复制。

enum GoutouChatRole: String, Codable, CaseIterable {
    case me
    case other

    /// 界面上的中文（剪贴板 JSON 里仍然写 me / other）。
    var displayName: String {
        switch self {
        case .me: return "我"
        case .other: return "对方"
        }
    }
}

struct GoutouChatClipboardMessage: Codable, Equatable {
    let role: GoutouChatRole
    let text: String
}

/// 剪贴板里那份 JSON 的结构。`format` / `version` 是识别标记，
/// 键盘那边先认标记再认版本，最后才看内容。
struct GoutouChatClipboardPayload: Equatable {
    static let format = "goutou-chat"
    static let version = 1

    let messages: [GoutouChatClipboardMessage]
}

// MARK: - 错误（每条都能直接给人看）

enum GoutouChatClipboardError: LocalizedError, Equatable {
    /// 不是 JSON，或者 JSON 里没有我们的 format 标记。
    case notOurFormat
    case malformedJSON
    /// version 字段存在，但不是「数值类型的整数」（字符串、小数、布尔、null 都算）。
    case invalidVersionType
    case unsupportedVersion(Int)
    case emptyMessages
    case tooManyMessages(limit: Int)
    /// 整段 JSON 超过 `GoutouChatClipboardCodec.maxEncodedLength`：在解析前就拦下，避免撑爆内存。
    case inputTooLong(length: Int, limit: Int)
    case emptyMessage(index: Int)
    case messageTooLong(index: Int, length: Int, limit: Int)
    case invalidRole(index: Int, value: String)

    var errorDescription: String? {
        switch self {
        case .notOurFormat:
            return "剪贴板里的内容不是狗头聊天格式（缺少 \(GoutouChatClipboardPayload.format) 标记）。先在 App 里点「复制聊天文字」。"
        case .malformedJSON:
            return "剪贴板里的聊天 JSON 结构不对（messages 不是数组、字段类型不对，或某个数值超出 JSON 解析范围）。重新在 App 里复制一次。"
        case .invalidVersionType:
            return "聊天 JSON 的 version 必须是整数（不能是字符串、小数或 true/false）。这份内容可能被改坏了，重新在 App 里复制一次。"
        case .unsupportedVersion(let version):
            return "这份聊天是 v\(version) 格式，当前只认 v\(GoutouChatClipboardPayload.version)。请更新 App 后重新复制。"
        case .emptyMessages:
            return "剪贴板里没有可导入的聊天内容（messages 是空的）。"
        case .tooManyMessages(let limit):
            return "聊天条数超过上限 \(limit) 条，先只复制其中一部分。"
        case .inputTooLong(let length, let limit):
            return "剪贴板里的内容有 \(length) 个字符，超过上限 \(limit) 个字符，不像是聊天 JSON。先清空剪贴板再复制一次。"
        case .emptyMessage(let index):
            return "聊天第 \(index) 条是空的，无法导入。"
        case .messageTooLong(let index, let length, let limit):
            return "聊天第 \(index) 条有 \(length) 字，超过上限 \(limit) 字，可能复制不全。"
        case .invalidRole(let index, let value):
            return "聊天第 \(index) 条的 role 是「\(value)」，只认 me / other。"
        }
    }
}

// MARK: - 编解码

/// App（写入）与键盘（读取）共用这一份实现。
///
/// 四条硬约束：
/// 1. 同一份聊天编码出来的字符串**完全一致**（`sortedKeys`，不依赖字典遍历顺序），
///    后续阶段判断「这份内容是不是刚导入过」直接比字符串即可。
/// 2. 只做同步、纯内存的转换：不碰文件、不碰网络、不碰 UIPasteboard（写剪贴板是调用方的事）。
/// 3. 出错时说人话，由调用方决定怎么展示，不打印聊天内容。
/// 4. **所有体量上限都集中在本类型的静态常量里**，编码和解码共用同一套口径，
///    不存在「写得出来、读不回去」的组合；解码还会在解析前先卡总长度。
enum GoutouChatClipboardCodec {

    // MARK: 体量上限（只在这里定义，改口径只改这一处）

    /// 一次最多导入多少条（防手滑贴一屏，也防请求体过大）。
    static let maxMessages = 200
    /// 单条最长多少字。
    static let maxMessageLength = 2000

    /// 整段 JSON 的字符数上限。
    ///
    /// 理论上限 = 条数 × 单条字数 × 每个字符最坏情况占用的字节（UTF-8 里 emoji 是 4 字节，
    /// JSON 转义 `\uXXXX` 再翻一倍），所以 200 × 2000 × 8 = 3_200_000 已经能装下任何合法内容。
    /// 往上取整到 3_500_000，既不会误伤合法内容，又能在 `JSONSerialization` 之前
    /// 把「随手复制了一篇几十万字的文章」这类输入挡在门外。
    static let maxEncodedLength = 3_500_000

    // MARK: 编码

    static func encode(_ payload: GoutouChatClipboardPayload) throws -> String {
        try validate(payload)

        let messages: [[String: Any]] = payload.messages.map { message in
            // 和校验口径保持一致：写出去的也是 trim 过的。
            ["role": message.role.rawValue, "text": clipboardTrimmed(message.text)]
        }
        let object: [String: Any] = [
            "format": GoutouChatClipboardPayload.format,
            "version": GoutouChatClipboardPayload.version,
            "messages": messages,
        ]

        let data: Data
        do {
            // `.sortedKeys` + 紧凑输出：同样的内容永远得到同样的字符串。
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw GoutouChatClipboardError.malformedJSON
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GoutouChatClipboardError.malformedJSON
        }
        // 校验口径和 `decode` 完全一样，保证「写得出来的一定读得回去」。
        guard text.count <= maxEncodedLength else {
            throw GoutouChatClipboardError.inputTooLong(length: text.count, limit: maxEncodedLength)
        }
        return text
    }

    // MARK: 解码

    /// 剪贴板里存的是别的东西（配置文本、随手复制的句子）时必须抛错，不能瞎认。
    static func decode(_ rawText: String) throws -> GoutouChatClipboardPayload {
        // 剪贴板经常带首尾换行 / 空格。
        let text = clipboardTrimmed(rawText)
        guard !text.isEmpty else {
            throw GoutouChatClipboardError.notOurFormat
        }
        // 先卡长度再解析：`JSONSerialization` 会把整段数据建成对象树，
        // 巨大输入在「格式校验」之前就已经把内存吃掉了。
        guard text.count <= maxEncodedLength else {
            throw GoutouChatClipboardError.inputTooLong(length: text.count, limit: maxEncodedLength)
        }
        guard let data = text.data(using: .utf8) else {
            throw GoutouChatClipboardError.notOurFormat
        }

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // 两条分支要分开：
            // - 完全不是 JSON（随手复制的句子、配置文本、顶层是数组）→「不是我们的格式」，提示指向正确做法；
            // - 是我们的格式标记、但 JSON 本身坏了（例如 `1e400` 这种 Foundation 直接拒绝的数值）
            //   →「结构异常」，这才是它真实的毛病。
            throw dataLooksLikeOurs(data)
                ? GoutouChatClipboardError.malformedJSON
                : GoutouChatClipboardError.notOurFormat
        }

        guard let format = object["format"] as? String,
              format == GoutouChatClipboardPayload.format else {
            throw GoutouChatClipboardError.notOurFormat
        }

        // version 单独看：将来升到 2 时要能明确说「版本不认识」，
        // 而不是含糊的「格式异常」。
        //
        // 这里是严格校验，**不能**用 `NSNumber.intValue`：
        // 它会把 `1.5` 截成 `1`、把 `true` 当成 `1`，于是坏数据被当成合法 v1 放进来。
        let version: Int
        switch strictInteger(object["version"]) {
        case .integer(let value):
            version = value
        case .notAnInteger:
            throw GoutouChatClipboardError.invalidVersionType
        case .missing:
            // 连 version 字段都没有，那连「我们家的东西」都不算。
            throw GoutouChatClipboardError.notOurFormat
        }
        guard version == GoutouChatClipboardPayload.version else {
            // 整数但比当前新（或更老）：明确说版本不支持。
            throw GoutouChatClipboardError.unsupportedVersion(version)
        }

        guard let rawMessages = object["messages"] as? [Any] else {
            throw GoutouChatClipboardError.malformedJSON
        }
        guard !rawMessages.isEmpty else {
            throw GoutouChatClipboardError.emptyMessages
        }
        guard rawMessages.count <= maxMessages else {
            throw GoutouChatClipboardError.tooManyMessages(limit: maxMessages)
        }

        var messages: [GoutouChatClipboardMessage] = []
        messages.reserveCapacity(rawMessages.count)
        for (offset, element) in rawMessages.enumerated() {
            let index = offset + 1
            guard let item = element as? [String: Any] else {
                throw GoutouChatClipboardError.malformedJSON
            }
            guard let roleText = item["role"] as? String else {
                throw GoutouChatClipboardError.malformedJSON
            }
            guard let role = GoutouChatRole(rawValue: roleText) else {
                throw GoutouChatClipboardError.invalidRole(index: index, value: roleText)
            }
            guard let messageText = item["text"] as? String else {
                throw GoutouChatClipboardError.malformedJSON
            }
            let content = clipboardTrimmed(messageText)
            guard !content.isEmpty else {
                throw GoutouChatClipboardError.emptyMessage(index: index)
            }
            guard content.count <= maxMessageLength else {
                throw GoutouChatClipboardError.messageTooLong(
                    index: index,
                    length: content.count,
                    limit: maxMessageLength
                )
            }
            messages.append(GoutouChatClipboardMessage(role: role, text: content))
        }

        return GoutouChatClipboardPayload(messages: messages)
    }

    /// 试着认一下剪贴板里是不是我们的格式——只用来决定提示措辞，不返回内容。
    static func looksLikeOurFormat(_ rawText: String) -> Bool {
        (try? decode(rawText)) != nil
    }

    // MARK: 校验（编码前先自检，避免写出键盘读不回来的东西）

    private static func validate(_ payload: GoutouChatClipboardPayload) throws {
        guard !payload.messages.isEmpty else {
            throw GoutouChatClipboardError.emptyMessages
        }
        guard payload.messages.count <= maxMessages else {
            throw GoutouChatClipboardError.tooManyMessages(limit: maxMessages)
        }
        for (offset, message) in payload.messages.enumerated() {
            let index = offset + 1
            let content = clipboardTrimmed(message.text)
            guard !content.isEmpty else {
                throw GoutouChatClipboardError.emptyMessage(index: index)
            }
            guard content.count <= maxMessageLength else {
                throw GoutouChatClipboardError.messageTooLong(
                    index: index,
                    length: content.count,
                    limit: maxMessageLength
                )
            }
        }
    }

    /// JSON 解不出来时，用来判断「这是不是一份坏掉的自家格式」。
    ///
    /// 只看有没有我们的 format 标记，不做任何解码；解析失败才走这里，所以不会成为热路径。
    private static func dataLooksLikeOurs(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(GoutouChatClipboardPayload.format)
    }

    // MARK: version 的严格取值

    private enum StrictInteger {
        case missing
        case notAnInteger
        case integer(Int)
    }

    /// 只接受「布尔以外的数值类型，且恰好等于某个整数」。
    ///
    /// 拒绝清单（都必须失败，不允许截断）：
    /// - `"1"` / `"1.0"`（字符串）→ `notAnInteger`
    /// - `1.5` / `-1.5`（小数）→ `notAnInteger`
    /// - `true` / `false`（JSON 布尔，Foundation 里也是 NSNumber）→ `notAnInteger`
    /// - `null` → `notAnInteger`
    /// - `1e400`（解析成无穷大）→ `notAnInteger`
    /// - `9.3e18`（超出 Int64）→ `notAnInteger`，不崩、不环绕
    ///
    /// 接受：整数类型的整数，以及数值上恰好是整数的浮点（`2.0`）。
    private static func strictInteger(_ any: Any?) -> StrictInteger {
        switch any {
        case nil:
            return .missing
        case is NSNull:
            return .notAnInteger
        case is String:
            return .notAnInteger
        case let value as NSNumber:
            if isBoolean(value) { return .notAnInteger }
            // CFNumberIsFloatType：整数类型的 NSNumber 在这里是 false，浮点是 true。
            if CFNumberIsFloatType(value) {
                let double = value.doubleValue
                // 无穷大 / NaN / 超出双精度能精确表示整数的范围：一律拒绝，
                // 别让 Int 转换去环绕。
                guard double.isFinite,
                      double >= -9.007199254740992e15,
                      double <= 9.007199254740992e15,
                      double.rounded(.towardZero) == double else {
                    return .notAnInteger
                }
                return .integer(Int(double))
            }
            // 整数类型：Int64 一定能转成 Int（Int 在 64 位平台就是 64 位）。
            return .integer(value.intValue)
        default:
            return .notAnInteger
        }
    }

    /// JSON 的 `true` / `false` 在 Foundation 里是 `NSNumber`，且都是 `CFBoolean`。
    private static func isBoolean(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }
}

/// 自带一份 trim，不用 `GoutouConfig.swift` 里那份 `String.trimmed`：
/// 那个文件不在 `tools/ChatLayoutCheck` 的独立编译范围里，自己带着才能单飞
/// （两端和冒烟测试编译的都是同一个文件，行为只有这一处定义）。
private func clipboardTrimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}
