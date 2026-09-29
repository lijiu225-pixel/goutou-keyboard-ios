import Foundation

/// 军师上下文（你叠进去的那几段对话）的本地存取。
///
/// 原本的设计是"上下文只放内存、不落盘"（怕聊天内容写进磁盘）。
/// 真机上用下来发现：切走 App 或者键盘扩展被系统回收之后，刚叠好的几段会凭空消失，
/// 这比隐私顾虑更烦人。所以改成落盘，**存到你手动点「✕ 清空上下文」为止**。
///
/// 存在键盘扩展自己的 UserDefaults 里（不是共享容器，别的 App 读不到）。
enum GoutouSegmentStore {

    static let storageKey = "goutou.mentor.segments"

    static func load(from defaults: UserDefaults = .standard) -> [GoutouSegment] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([GoutouSegment].self, from: data)) ?? []
    }

    static func save(_ segments: [GoutouSegment], to defaults: UserDefaults = .standard) {
        guard !segments.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(segments) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
