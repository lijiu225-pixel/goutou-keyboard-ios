import Foundation

/// 军师上下文（你叠进去的那几段对话）的读写。
///
/// **第六阶段起读写的是「当前人物档案」里那份**（一人一份），
/// 但对外 API 一个字没改，所以控制器里的调用点不用动。
///
/// 原本设计是"只放内存不落盘"；真机发现切走 App / 键盘被系统回收就丢，
/// 改成落盘，**存到你手动点「✕ 清空上下文」为止**。
enum GoutouSegmentStore {

    static func load(from defaults: UserDefaults = .standard) -> [GoutouSegment] {
        GoutouProfileStore.activeProfile(from: defaults).segments
    }

    static func save(_ segments: [GoutouSegment], to defaults: UserDefaults = .standard) {
        GoutouProfileStore.updateActive({ $0.segments = segments }, in: defaults)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        GoutouProfileStore.updateActive({ $0.segments = [] }, in: defaults)
    }
}
