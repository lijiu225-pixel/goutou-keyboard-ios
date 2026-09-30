import Foundation

/// This group is present in BOTH embedded profiles and signatures of the supplied re-signed IPA.
/// Provider-owned group: project directories avoid collisions, not access by other group members.
enum SharedConstants {
    static let appGroupID = "group.GDK748UUB7.pOgtZpt"
    static let probeDirectory = "com.example.goutouinput.diagnostics"
    static let probeFilename = "app_group_probe.json"
    static let chatDirectory = "com.example.goutouinput.chat"
    static let latestChatFilename = "latest_chat.json"
}
