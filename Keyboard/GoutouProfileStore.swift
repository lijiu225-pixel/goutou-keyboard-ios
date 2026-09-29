import Foundation

/// 一个人物的「AI 总结」（最后一次分析结果），按档案分别保存。
struct GoutouSavedSummary: Codable, Equatable {
    var headline: String
    var replies: [String]
    var savedAt: Date
}

/// 一个人物档案：背景（segments）、记忆（memory）、AI 总结都是这一份里的。
///
/// 人格（`GoutouSkill.md`）是全局共用的，档案里**不存人格**——第六阶段明确不做人格库。
struct GoutouPersonProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var note: String = ""
    var segments: [GoutouSegment] = []
    var memory: [GoutouMemoryItem] = []
    var summary: GoutouSavedSummary?
    var updatedAt: Date = Date()

    init(
        id: String,
        name: String,
        note: String = "",
        segments: [GoutouSegment] = [],
        memory: [GoutouMemoryItem] = [],
        summary: GoutouSavedSummary? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.segments = segments
        self.memory = memory
        self.summary = summary
        self.updatedAt = updatedAt
    }

    /// 手写解码：以后加字段时，老数据也不会因为缺 key 而整份解不出来
    /// （解不出来就会走迁移逻辑，等于把档案清了——那太贵了）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        segments = try container.decodeIfPresent([GoutouSegment].self, forKey: .segments) ?? []
        // 记忆两种形态都认：新的结构化条目，以及老版本的纯字符串数组（自动升级成「手工加的稳定事实」）
        if let items = try? container.decode([GoutouMemoryItem].self, forKey: .memory) {
            memory = items.map { item in
                var copy = item
                if copy.personID.isEmpty { copy.personID = id }
                return copy
            }
        } else if let legacy = try? container.decode([String].self, forKey: .memory) {
            memory = legacy.map { GoutouMemoryItem(personID: id, content: $0, source: "manual") }
        } else {
            memory = []
        }
        summary = try container.decodeIfPresent(GoutouSavedSummary.self, forKey: .summary)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// 档案总表 + 当前选中的人。
struct GoutouProfileBook: Codable, Equatable {
    var profiles: [GoutouPersonProfile]
    var activeProfileID: String
}

/// 多人档案的读写。仍然只用键盘扩展自己的 UserDefaults（没有 App Group）。
///
/// 迁移：老版本把上下文和记忆分别存在 `goutou.mentor.segments` / `goutou.mentor.memory`，
/// 第一次读时会把它们装进一个叫「默认」的档案，然后删掉旧键——老数据不会丢。
enum GoutouProfileStore {

    static let storageKey = "goutou.mentor.profiles"
    static let legacySegmentsKey = "goutou.mentor.segments"
    static let legacyMemoryKey = "goutou.mentor.memory"

    static let defaultProfileName = "默认"

    // MARK: - 读

    static func loadBook(from defaults: UserDefaults = .standard) -> GoutouProfileBook {
        if let data = defaults.data(forKey: storageKey),
           let book = try? JSONDecoder().decode(GoutouProfileBook.self, from: data),
           !book.profiles.isEmpty {
            return book
        }
        let migrated = migrateLegacy(from: defaults)
        save(migrated, to: defaults)
        return migrated
    }

    static func activeProfile(from defaults: UserDefaults = .standard) -> GoutouPersonProfile {
        let book = loadBook(from: defaults)
        return book.profiles.first { $0.id == book.activeProfileID } ?? book.profiles[0]
    }

    static func save(_ book: GoutouProfileBook, to defaults: UserDefaults = .standard) {
        guard !book.profiles.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(book) else { return }
        defaults.set(data, forKey: storageKey)
    }

    // MARK: - 写当前人物

    /// 改当前人物的某个字段（segments / memory / summary），其余档案原样保留。
    static func updateActive(_ mutate: (inout GoutouPersonProfile) -> Void, in defaults: UserDefaults = .standard) {
        var book = loadBook(from: defaults)
        guard let index = book.profiles.firstIndex(where: { $0.id == book.activeProfileID }) else { return }
        mutate(&book.profiles[index])
        book.profiles[index].updatedAt = Date()
        save(book, to: defaults)
    }

    // MARK: - 人物管理

    @discardableResult
    static func create(name: String, in defaults: UserDefaults = .standard) -> GoutouPersonProfile {
        var book = loadBook(from: defaults)
        let profile = GoutouPersonProfile(id: UUID().uuidString, name: name)
        book.profiles.append(profile)
        book.activeProfileID = profile.id
        save(book, to: defaults)
        return profile
    }

    static func select(id: String, in defaults: UserDefaults = .standard) {
        var book = loadBook(from: defaults)
        guard book.profiles.contains(where: { $0.id == id }) else { return }
        book.activeProfileID = id
        save(book, to: defaults)
    }

    static func rename(id: String, to name: String, in defaults: UserDefaults = .standard) {
        var book = loadBook(from: defaults)
        guard let index = book.profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmed
        guard !trimmed.isEmpty else { return }
        book.profiles[index].name = trimmed
        save(book, to: defaults)
    }

    /// 删掉一个人物；只剩一个时不允许删（否则就没有「当前人物」了）。
    static func delete(id: String, in defaults: UserDefaults = .standard) {
        var book = loadBook(from: defaults)
        guard book.profiles.count > 1 else { return }
        book.profiles.removeAll { $0.id == id }
        if book.activeProfileID == id, let first = book.profiles.first {
            book.activeProfileID = first.id
        }
        save(book, to: defaults)
    }

    // MARK: - 迁移

    static func migrateLegacy(from defaults: UserDefaults = .standard) -> GoutouProfileBook {
        var profile = GoutouPersonProfile(id: UUID().uuidString, name: defaultProfileName)
        if let data = defaults.data(forKey: legacySegmentsKey),
           let segments = try? JSONDecoder().decode([GoutouSegment].self, from: data) {
            profile.segments = segments
        }
        if let data = defaults.data(forKey: legacyMemoryKey),
           let legacy = try? JSONDecoder().decode([String].self, from: data) {
            // 老版本的记忆是纯字符串数组，升级成结构化条目（都算你手工加的稳定事实）
            profile.memory = legacy.map {
                GoutouMemoryItem(personID: profile.id, content: $0, source: "manual")
            }
        }
        // 迁移完就把旧键删掉，避免以后又读一遍旧数据
        defaults.removeObject(forKey: legacySegmentsKey)
        defaults.removeObject(forKey: legacyMemoryKey)
        return GoutouProfileBook(profiles: [profile], activeProfileID: profile.id)
    }
}
