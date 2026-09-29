import Foundation

/// 军师的「长期档案」（记忆）：一些你知道但对话里看不出来的事实
/// （她生日是 3 月 5 日、我们认识三个月、上次吵架是因为……）。
///
/// **第六阶段起一人一份**——都存在当前人物档案里，不同人的记忆不会串。
/// 这些内容每次分析都会带上，用来养这个军师。
enum GoutouMemoryStore {

    static func load(from defaults: UserDefaults = .standard) -> [String] {
        GoutouProfileStore.activeProfile(from: defaults).memory
    }

    static func save(_ entries: [String], to defaults: UserDefaults = .standard) {
        let cleaned = entries.map { $0.trimmed }.filter { !$0.isEmpty }
        GoutouProfileStore.updateActive({ $0.memory = cleaned }, in: defaults)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        GoutouProfileStore.updateActive({ $0.memory = [] }, in: defaults)
    }
}
