import Foundation

/// This group is present in BOTH embedded profiles and signatures of the supplied re-signed IPA.
/// Provider-owned group: only a fixed, non-sensitive probe is stored at this stage.
enum SharedConstants {
    static let appGroupID = "group.GDK748UUB7.pOgtZpt"
    static let probeDirectory = "com.example.goutouinput.diagnostics"
    static let probeFilename = "app_group_probe.json"
}
