import Foundation

/// 军师的「长期档案」：一些你知道但对话里看不出来的事实
/// （她生日是 3 月 5 日、我们认识三个月、上次吵架是因为……）。
///
/// 这些内容每次分析都会一起发给模型，用来养这个军师——不然每次都从零开始，
/// 它会反复问你已经告诉过它的事。
///
/// 存键盘自己的 UserDefaults，和上下文一样：只有你手动删才会没。
enum GoutouMemoryStore {

    static let storageKey = "goutou.mentor.memory"

    static func load(from defaults: UserDefaults = .standard) -> [String] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func save(_ entries: [String], to defaults: UserDefaults = .standard) {
        let cleaned = entries
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(cleaned) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
