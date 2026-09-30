import Foundation

/// 阶段 12D 的全部阈值：集中一处，方便调参也方便测试；不埋在 UI 里，也不散落 magic number。
struct LiveChatAutoSyncConfiguration: Equatable {
    /// 聊天停止变化多久之后才写盘（debounce）：这段时间里每次更新都会重新计时。
    var debounceInterval: TimeInterval = 1.5
    /// 两次真正写盘之间至少隔这么久，避免极端情况下频繁原子替换。
    var minimumSaveInterval: TimeInterval = 2.0
    /// 指纹算法版本：改了拼法就把它一起改掉，免得把旧指纹当成同一份内容。
    var fingerprintVersion = "v2"

    static let `default` = LiveChatAutoSyncConfiguration()
}
