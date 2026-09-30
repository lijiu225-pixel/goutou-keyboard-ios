import Foundation

/// Reads from disk each time; no process-local cache that can go stale.
enum ChatSharingStatus {
    static func read() -> String {
        do {
            guard let snapshot = try SharedChatStore().load() else {
                return "共享聊天：暂无缓存"
            }
            let suffix = snapshot.isExpired() ? "（已过期）" : "（新鲜）"
            return "共享聊天：\(snapshot.messages.count) 条\(suffix)"
        } catch {
            // Never expose filesystem paths or chat text through error logs/UI.
            return "共享聊天不可用，请检查签名和完全访问权限"
        }
    }
}
