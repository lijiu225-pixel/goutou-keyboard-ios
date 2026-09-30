import CryptoKit
import Foundation

/// deterministic 的聊天内容指纹：按顺序拼 `role|text` 再取 SHA-256。
///
/// App 与 Keyboard 共用同一套算法，免得两边对「是不是同一份聊天」判断不一致：
/// - 主 App 的自动同步（阶段 12D）用它判断内容有没有真的变化；
/// - 键盘（阶段 12E）用它判断共享聊天是不是比当前上下文新。
///
/// 只用于内存比较，**绝不写进正式 JSON**；也不用带随机 seed 的 Swift `Hasher`。
enum SharedChatFingerprint {
    static func make(messages: [GoutouChatClipboardMessage], version: String = "v1") -> String {
        var text = version
        for message in messages {
            text += "\n\(message.role.rawValue)|\(message.text)"
        }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
