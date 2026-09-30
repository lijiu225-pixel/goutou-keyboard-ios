# App Group probe stage

The supplied re-signed IPA has the same five application groups in both actual Mach-O signatures and both embedded provisioning profiles. Both targets use bundle IDs com.example.goutouinput and com.example.goutouinput.keyboard. We selected group.GDK748UUB7.pOgtZpt for a fixed, non-sensitive probe only. This is provider-owned; exclusivity for private chat data is not established. Embedded metadata inspection does not cryptographically verify the signatures.

Both XcodeGen targets now specify matching entitlements. Re-signing can replace these entitlements: inspect BOTH final binaries and profiles again when the new IPA is supplied. Unsigned CI output cannot prove runtime container authorization. RequestsOpenAccess remains enabled.

Main app: App Group 诊断 → 写入测试数据. Keyboard: allow full access → 军师 → 设置 → 读取 App Group 测试. The displayed timestamp must match the latest main-app write. Repeat the write and read to rule out a stale probe. The file is com.example.goutouinput.diagnostics/app_group_probe.json inside the authorized container, never a private Documents fallback. No chat data is written.

CI checks temporary-directory round trips, replacement, missing/unavailable containers, malformed/oversized records, source/value/timestamp validation and write failure. These are filesystem contract tests, not an iPhone entitlement test.

Pending: phone runtime probe, inspection of the newly re-signed IPA, group usage scope. Only after the phone probe succeeds may SharedChatStore/latest_chat.json and OCR save/read integration be implemented. No AI or screen capture is added in this stage.
