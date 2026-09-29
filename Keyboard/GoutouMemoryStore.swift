import Foundation

/// 某个人的「长期档案」（记忆）读写。
///
/// **一人一份**：全部存在当前人物档案里，不同人的记忆不会串。
/// 每条记忆带 id + personID + 分类 + 重要度/置信度 + 时间戳；
/// 自动归纳（MemoryExtractor）和手工添加都走这里，**AI 只能改不能删**。
enum GoutouMemoryStore {

    static func load(from defaults: UserDefaults = .standard) -> [GoutouMemoryItem] {
        GoutouProfileStore.activeProfile(from: defaults).memory
    }

    /// 整批替换当前人物的记忆（自动归纳的事务提交点）。
    static func replaceAll(_ items: [GoutouMemoryItem], from defaults: UserDefaults = .standard) {
        let cleaned = items.filter { !$0.content.trimmed.isEmpty }
        GoutouProfileStore.updateActive({ $0.memory = cleaned }, in: defaults)
    }

    /// 手工加一条（记忆页的「从剪贴板导入一条」走这里）。
    static func append(_ content: String, to defaults: UserDefaults = .standard) {
        let text = content.trimmed
        guard !text.isEmpty else { return }
        let personID = GoutouProfileStore.activeProfile(from: defaults).id
        var items = load(from: defaults)
        items.append(GoutouMemoryItem(personID: personID, content: text, source: "manual"))
        replaceAll(items, from: defaults)
    }

    static func remove(id: String, from defaults: UserDefaults = .standard) {
        var items = load(from: defaults)
        items.removeAll { $0.id == id }
        replaceAll(items, from: defaults)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        GoutouProfileStore.updateActive({ $0.memory = [] }, in: defaults)
    }
}
