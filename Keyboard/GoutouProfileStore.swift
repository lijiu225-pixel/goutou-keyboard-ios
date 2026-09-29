import Foundation

/// 一个人物的「AI 总结」（最后一次分析结果），按档案分别保存。
struct GoutouSavedSummary: Codable, Equatable {
    var headline: String
    var replies: [String]
    var savedAt: Date
}

/// 一个人物档案：背景（segments）、记忆（memory）、AI 总结都是这一份里的。
///
/// 人格（`GoutouSkill.md`）是全局共用的，档案里**不存人格**。
/// `id` 是永久身份（UUID），所有对人物下数据的操作都用它。
struct GoutouPersonProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var note: String
    var segments: [GoutouSegment]
    var memory: [PersonMemory]
    var summary: GoutouSavedSummary?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        note: String = "",
        segments: [GoutouSegment] = [],
        memory: [PersonMemory] = [],
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

    enum CodingKeys: String, CodingKey {
        case id, name, note, segments, memory, summary, updatedAt
    }

    /// 手写解码：以后加字段时老数据也不会因为缺 key 整份读不出来；
    /// 顺便把老版本的记忆形态（纯字符串 / v1 条目）一次性升级，并把归属纠正为本档案。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名"
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        segments = try container.decodeIfPresent([GoutouSegment].self, forKey: .segments) ?? []

        if let items = try? container.decode([PersonMemory].self, forKey: .memory) {
            memory = items.map { item in
                var copy = item
                // 记忆归属一律以所属档案为准：旧数据缺 personID、或写错的，这里一次性纠正
                copy.personID = id
                return copy
            }
        } else if let legacy = try? container.decode([String].self, forKey: .memory) {
            // v0：纯字符串数组 → 迁移成条目（分类未知用 other，来源记 migratedLegacy）
            let now = Date()
            memory = legacy.map {
                PersonMemory(
                    personID: id,
                    content: $0,
                    category: .other,
                    sourceType: .migratedLegacy,
                    createdAt: now,
                    updatedAt: now,
                    lastConfirmedAt: nil,
                    archived: false
                )
            }
        } else {
            memory = []
        }

        summary = try container.decodeIfPresent(GoutouSavedSummary.self, forKey: .summary)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// 档案总表 + 当前选中的人 + 记忆 Schema 版本。
struct GoutouProfileBook: Codable, Equatable {
    var profiles: [GoutouPersonProfile]
    var activeProfileID: UUID
    /// 记忆结构的迁移版本：写进去就说明迁移做过了，不再重复迁移
    var memorySchemaVersion: Int

    init(
        profiles: [GoutouPersonProfile],
        activeProfileID: UUID,
        memorySchemaVersion: Int = GoutouProfileStore.currentMemorySchemaVersion
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.memorySchemaVersion = memorySchemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decodeIfPresent([GoutouPersonProfile].self, forKey: .profiles) ?? []
        activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
            ?? profiles.first?.id
            ?? UUID()
        memorySchemaVersion = try container.decodeIfPresent(Int.self, forKey: .memorySchemaVersion) ?? 1
    }
}

/// 多人档案的读写。仍然只用键盘扩展自己的 UserDefaults（没有 App Group）。
///
/// 迁移分两层，都是幂等的：
/// 1. 老键 `goutou.mentor.segments` / `goutou.mentor.memory`（单人物时代）→ 装进「默认」档案；
/// 2. 档案内部的记忆形态：纯字符串（v0）→ 条目；v1 条目（`source` 字符串）→ v2（`sourceType` 等）。
enum GoutouProfileStore {

    static let storageKey = "goutou.mentor.profiles"
    static let backupKey = "goutou.mentor.profiles.backup"
    static let legacySegmentsKey = "goutou.mentor.segments"
    static let legacyMemoryKey = "goutou.mentor.memory"

    /// 当前记忆 Schema 版本（v2 = 带 UUID / 来源追踪 / 归档位）
    static let currentMemorySchemaVersion = 2
    static let defaultProfileName = "默认"

    // MARK: - 读

    static func loadBook(from defaults: UserDefaults = .standard) -> GoutouProfileBook {
        if let data = defaults.data(forKey: storageKey) {
            if let book = try? JSONDecoder().decode(GoutouProfileBook.self, from: data), !book.profiles.isEmpty {
                return applySchemaVersionIfNeeded(book, raw: data, in: defaults)
            }
            // 解不出来又要被覆盖：先把原文留一份备份，别把用户数据直接冲掉
            defaults.set(data, forKey: backupKey)
        }
        let migrated = migrateLegacyKeys(from: defaults)
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

    /// 迁移只写在版本号里，不重复搬数据（解出来的结构本身已经就地升级过）。
    private static func applySchemaVersionIfNeeded(
        _ book: GoutouProfileBook,
        raw: Data,
        in defaults: UserDefaults
    ) -> GoutouProfileBook {
        guard book.memorySchemaVersion < currentMemorySchemaVersion else { return book }
        defaults.set(raw, forKey: backupKey)
        var upgraded = book
        upgraded.memorySchemaVersion = currentMemorySchemaVersion
        save(upgraded, to: defaults)
        return upgraded
    }

    // MARK: - 写某个人物

    /// 按 personID 改档案（不认当前选中）；找不到这个人就返回 false。
    @discardableResult
    static func updateProfile(
        id: UUID,
        in defaults: UserDefaults = .standard,
        _ mutate: (inout GoutouPersonProfile) -> Void
    ) -> Bool {
        var book = loadBook(from: defaults)
        guard let index = book.profiles.firstIndex(where: { $0.id == id }) else { return false }
        mutate(&book.profiles[index])
        book.profiles[index].updatedAt = Date()
        save(book, to: defaults)
        return true
    }

    // MARK: - 人物管理

    @discardableResult
    static func create(name: String, in defaults: UserDefaults = .standard) -> GoutouPersonProfile {
        var book = loadBook(from: defaults)
        let profile = GoutouPersonProfile(name: name)
        book.profiles.append(profile)
        book.activeProfileID = profile.id
        save(book, to: defaults)
        return profile
    }

    static func select(id: UUID, in defaults: UserDefaults = .standard) {
        var book = loadBook(from: defaults)
        guard book.profiles.contains(where: { $0.id == id }) else { return }
        book.activeProfileID = id
        save(book, to: defaults)
    }

    static func rename(id: UUID, to name: String, in defaults: UserDefaults = .standard) {
        let trimmed = name.trimmed
        guard !trimmed.isEmpty else { return }
        updateProfile(id: id, in: defaults) { $0.name = trimmed }
    }

    /// 删掉一个人物；只剩一个时不允许删（否则就没有「当前人物」了）。
    static func delete(id: UUID, in defaults: UserDefaults = .standard) {
        var book = loadBook(from: defaults)
        guard book.profiles.count > 1 else { return }
        book.profiles.removeAll { $0.id == id }
        if book.activeProfileID == id, let first = book.profiles.first {
            book.activeProfileID = first.id
        }
        save(book, to: defaults)
    }

    // MARK: - 老键迁移

    static func migrateLegacyKeys(from defaults: UserDefaults = .standard) -> GoutouProfileBook {
        var profile = GoutouPersonProfile(name: defaultProfileName)
        if let data = defaults.data(forKey: legacySegmentsKey),
           let segments = try? JSONDecoder().decode([GoutouSegment].self, from: data) {
            profile.segments = segments
        }
        if let data = defaults.data(forKey: legacyMemoryKey),
           let legacy = try? JSONDecoder().decode([String].self, from: data) {
            let now = Date()
            profile.memory = legacy.map {
                PersonMemory(
                    personID: profile.id,
                    content: $0,
                    category: .other,
                    sourceType: .migratedLegacy,
                    createdAt: now,
                    updatedAt: now,
                    lastConfirmedAt: nil,
                    archived: false
                )
            }
        }
        // 迁移完就把旧键删掉，避免以后又读一遍旧数据
        defaults.removeObject(forKey: legacySegmentsKey)
        defaults.removeObject(forKey: legacyMemoryKey)
        return GoutouProfileBook(profiles: [profile], activeProfileID: profile.id)
    }
}
