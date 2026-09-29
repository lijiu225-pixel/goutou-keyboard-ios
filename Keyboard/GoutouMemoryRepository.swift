import Foundation

enum MemoryRepositoryError: Error, Equatable {
    /// 这个人不存在
    case personNotFound
    /// 这个人的名下没有这条记忆
    case memoryNotFound
    /// 拿别的 id 来改这个人（记忆的 personID 和传入的 personID 不一致）
    case personMismatch
    case emptyContent
}

/// 记忆的**唯一访问层**：人物隔离、按 id 操作、时间字段规则都在这里。
///
/// 两条硬规矩：
/// 1. 所有方法都要显式传 `personID`——**故意不提供 `getAllMemories()`**，
///    免得哪天有人顺手把所有人的记忆都塞进 prompt；
/// 2. 所有改动都按 `memory.id` 定位，绝不拿数组下标当身份。
enum GoutouMemoryRepository {

    // MARK: - 查

    /// 某个人当前的记忆。默认不返回已归档的；PromptBuilder 也只该走这一个入口。
    static func getMemories(
        personID: UUID,
        includeArchived: Bool = false,
        from defaults: UserDefaults = .standard
    ) -> [PersonMemory] {
        guard let profile = profile(id: personID, in: defaults) else { return [] }
        return includeArchived ? profile.memory : profile.memory.filter { !$0.archived }
    }

    static func getMemory(id: UUID, personID: UUID, from defaults: UserDefaults = .standard) -> PersonMemory? {
        getMemories(personID: personID, includeArchived: true, from: defaults).first { $0.id == id }
    }

    // MARK: - 增

    @discardableResult
    static func addMemory(
        content: String,
        personID: UUID,
        category: MemoryCategory = .stableFact,
        importance: Int = 3,
        confidence: Double = 1.0,
        sourceType: MemorySourceType = .manual,
        sourceSessionID: UUID? = nil,
        sourceMessageStart: Int? = nil,
        sourceMessageEnd: Int? = nil,
        from defaults: UserDefaults = .standard
    ) throws -> PersonMemory {
        let text = content.trimmed
        guard !text.isEmpty else { throw MemoryRepositoryError.emptyContent }
        guard profile(id: personID, in: defaults) != nil else { throw MemoryRepositoryError.personNotFound }

        let now = Date()
        // createdAt / updatedAt 一致；personID 绑定调用方传进来的人
        let memory = PersonMemory(
            personID: personID,
            content: text,
            category: category,
            importance: GoutouMemoryApplier.clampImportance(importance),
            confidence: GoutouMemoryApplier.clampConfidence(confidence),
            createdAt: now,
            updatedAt: now,
            lastConfirmedAt: nil,
            sourceType: sourceType,
            sourceSessionID: sourceSessionID,
            sourceMessageStart: sourceMessageStart,
            sourceMessageEnd: sourceMessageEnd,
            archived: false
        )
        GoutouProfileStore.updateProfile(id: personID, in: defaults) { $0.memory.append(memory) }
        return memory
    }

    // MARK: - 改

    /// 按 id 改内容（编辑只动 `updatedAt`，`createdAt` 永远不变）。
    @discardableResult
    static func updateMemory(
        id: UUID,
        personID: UUID,
        from defaults: UserDefaults = .standard,
        _ mutate: (inout PersonMemory) -> Void
    ) throws -> PersonMemory {
        guard var profile = profile(id: personID, in: defaults) else { throw MemoryRepositoryError.personNotFound }
        guard let index = profile.memory.firstIndex(where: { $0.id == id }) else {
            throw isKnownElsewhere(id: id, excluding: personID, in: defaults)
                ? MemoryRepositoryError.personMismatch
                : MemoryRepositoryError.memoryNotFound
        }

        var memory = profile.memory[index]
        // id / personID / createdAT 都是 `let`——「身份不改、createdAt 永不覆盖」由类型强制，
        // 这里不需要（也没法）再手动保护。
        mutate(&memory)
        memory.updatedAt = Date()
        if memory.content.trimmed.isEmpty { throw MemoryRepositoryError.emptyContent }

        profile.memory[index] = memory
        GoutouProfileStore.updateProfile(id: personID, in: defaults) { $0.memory = profile.memory }
        return memory
    }

    /// 带对象的重载：显式校验 `memory.personID == personID`，不一致直接拒。
    @discardableResult
    static func updateMemory(
        _ memory: PersonMemory,
        forPerson personID: UUID,
        from defaults: UserDefaults = .standard
    ) throws -> PersonMemory {
        guard memory.personID == personID else { throw MemoryRepositoryError.personMismatch }
        return try updateMemory(id: memory.id, personID: personID, from: defaults) { stored in
            stored.content = memory.content
            stored.category = memory.category
            stored.importance = memory.importance
            stored.confidence = memory.confidence
            stored.archived = memory.archived
        }
    }

    /// 「又确认了一次」：更新 `lastConfirmedAt` 和 `updatedAt`，内容不动。
    @discardableResult
    static func confirmMemory(
        id: UUID,
        personID: UUID,
        at date: Date = Date(),
        from defaults: UserDefaults = .standard
    ) throws -> PersonMemory {
        try updateMemory(id: id, personID: personID, from: defaults) { memory in
            memory.lastConfirmedAt = date
        }
    }

    // MARK: - 时间衰减 / stale（只读：绝不归档、绝不删除）

    /// 现在有哪些记忆「可能过时」——按 `MemoryDecay` 实时算，不写库。
    ///
    /// `stale != archived != deleted`：这里只是把名单挑出来（管理页 / 调试用），
    /// 数据本身一个字节都不动。
    static func getStaleMemories(
        personID: UUID,
        includeArchived: Bool = false,
        at now: Date = Date(),
        config: MemoryDecayConfig = .default,
        from defaults: UserDefaults = .standard
    ) -> [PersonMemory] {
        guard let profile = profile(id: personID, in: defaults) else { return [] }
        return profile.memory
            .filter { includeArchived || !$0.archived }
            .filter { MemoryDecay.isStale($0, at: now, config: config) }
    }

    /// 统一重算入口：返回这个人物现在有多少条 stale。
    ///
    /// 为什么没有「写回数据库」：本项目把 stale 设计成**算出来的**状态，而不是存一个 Bool——
    /// 存了就会出现「时间过去了，库里的值永远不刷新」的老问题。
    /// 所以这里只是按需算一次（查询 / 切换人物 / 打开记忆页 / 写入后调用都行），
    /// 没有 Timer、没有后台轮询、没有网络请求。
    @discardableResult
    static func refreshStaleState(
        personID: UUID,
        at now: Date = Date(),
        config: MemoryDecayConfig = .default,
        from defaults: UserDefaults = .standard
    ) -> Int {
        getStaleMemories(personID: personID, includeArchived: true, at: now, config: config, from: defaults).count
    }

    // MARK: - 归档 / 删

    static func archiveMemory(
        id: UUID,
        personID: UUID,
        archived: Bool = true,
        from defaults: UserDefaults = .standard
    ) throws {
        _ = try updateMemory(id: id, personID: personID, from: defaults) { memory in
            memory.archived = archived
        }
    }

    static func deleteMemory(id: UUID, personID: UUID, from defaults: UserDefaults = .standard) throws {
        guard var profile = profile(id: personID, in: defaults) else { throw MemoryRepositoryError.personNotFound }
        guard profile.memory.contains(where: { $0.id == id }) else {
            throw isKnownElsewhere(id: id, excluding: personID, in: defaults)
                ? MemoryRepositoryError.personMismatch
                : MemoryRepositoryError.memoryNotFound
        }
        profile.memory.removeAll { $0.id == id }
        GoutouProfileStore.updateProfile(id: personID, in: defaults) { $0.memory = profile.memory }
    }

    static func deleteAllMemories(personID: UUID, from defaults: UserDefaults = .standard) throws {
        guard profile(id: personID, in: defaults) != nil else { throw MemoryRepositoryError.personNotFound }
        GoutouProfileStore.updateProfile(id: personID, in: defaults) { $0.memory = [] }
    }

    /// 事务提交：把「算好的整份记忆」写回这个人（自动归纳一次落盘的地方）。
    /// 只收属于这个人的条目——别人的东西绝不会被写到这个名下。
    static func replaceMemories(_ memories: [PersonMemory], personID: UUID, from defaults: UserDefaults = .standard) throws {
        guard profile(id: personID, in: defaults) != nil else { throw MemoryRepositoryError.personNotFound }
        let owned = memories.filter { $0.personID == personID && !$0.content.trimmed.isEmpty }
        GoutouProfileStore.updateProfile(id: personID, in: defaults) { $0.memory = owned }
    }

    // MARK: - 内部

    private static func profile(id: UUID, in defaults: UserDefaults) -> GoutouPersonProfile? {
        GoutouProfileStore.loadBook(from: defaults).profiles.first { $0.id == id }
    }

    /// 这条记忆是不是挂在别的人物名下（用来区分「找不到」和「串人了」）
    private static func isKnownElsewhere(id: UUID, excluding personID: UUID, in defaults: UserDefaults) -> Bool {
        GoutouProfileStore.loadBook(from: defaults)
            .profiles
            .contains { $0.id != personID && $0.memory.contains { $0.id == id } }
    }
}
