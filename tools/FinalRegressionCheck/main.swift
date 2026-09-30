import Foundation

// These three regressions compile against both the pre-FINAL baseline and FINAL.
// CI must observe all three fail on the baseline and pass on the delivered source.
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}
var gate = ChatSceneGate()
_ = gate.update(isChatFrame: true, titleFingerprint: "fictional-A")
_ = gate.update(isChatFrame: true, titleFingerprint: "fictional-A")
_ = gate.update(isChatFrame: true, titleFingerprint: "fictional-B")
check(gate.update(isChatFrame: true, titleFingerprint: "fictional-B").startsNewSession,
      "confirmed-title-change")

let now = Date(timeIntervalSince1970: 1_700_000_000)
let message = LiveChatCandidate(text: "Synthetic", normalizedText: "Synthetic", role: .other,
    box: CGRect(x: 0.05, y: 0.3, width: 0.3, height: 0.03), confidence: 0.9, timestamp: now)
var sync = LiveChatAutoSyncSession()
_ = sync.resetForNewSession(generation: 1)
_ = sync.setEnabled(true, messages: [message], now: now)
let deadline = sync.pending?.deadline
_ = sync.noteTimeline(messages: [message], now: now.addingTimeInterval(0.8))
check(sync.pending?.deadline == deadline, "unchanged-frames-do-not-postpone-save")

let one = [GoutouChatClipboardMessage(role: .me, text: "a\nother|b")]
let two = [GoutouChatClipboardMessage(role: .me, text: "a"),
           GoutouChatClipboardMessage(role: .other, text: "b")]
check(SharedChatFingerprint.make(messages: one) != SharedChatFingerprint.make(messages: two),
      "unambiguous-fingerprint-framing")
exit(failures == 0 ? 0 : 1)
