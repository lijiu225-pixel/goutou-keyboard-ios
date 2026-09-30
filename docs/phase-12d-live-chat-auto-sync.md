# 阶段 12D：用户主动开启的实时聊天自动同步

在用户**明确开启**之后，动态识别拿到的、稳定且角色明确的实时聊天会自动更新到现有共享聊天，
不用每次回主 App 整理再保存：

```
ScreenCaptureKit → Vision OCR → LiveChatTimeline（12B 已稳定化）
  → 用户主动打开「自动同步给狗头军师」
  → eligibility（me/other、无 unknown）
  → deterministic fingerprint（内容没变就不写）
  → debounce 1.5s + 最低写入间隔 2s
  → 现有 SharedChatStore.save → App Group latest_chat.json
键盘仍然由用户自己「读取识别聊天 → 使用这份聊天 → 分析这段聊天」
```

本阶段**不**自动调 AI、**不**自动激活键盘上下文、**不**自动插入、**不**发送、**不**写人物记忆、
**不**修改键盘。

## 授权规则

- `autoSyncEnabled` 默认为 **false**：App 启动是关的，开始一轮新的 capture session 也是关的，
  也**不写偏好设置**（它是当前 capture session 的临时授权，不跨启动保留）。
- 只有用户主动点「自动同步给狗头军师」才会开始自动写共享聊天；关闭 / Stop / 人工保存之后都要
  用户再次明确开启。

## 状态机

`disabled / waitingForChat / blockedUnknown(count) / scheduled / syncing / synced(count, at) /
failed(reason) / pausedAfterManualSave`，UI 直接照着显示：
已关闭、等待聊天、等待稳定…、正在同步…、已同步 N 条、有 N 条消息归属未确定（已暂停）、
同步失败：原因、已按人工确认结果保存（已暂停）。

## Timeline → 正式 payload 的规则

- 只吃 `LiveChatTimeline` 里**已经 committed** 的消息；raw OCR observation、未稳定候选、pending 一律不用。
- `system`（时间 / 撤回提示 / 居中系统文字）：继续显示，但**永远不进**正式 payload。
- `unknown`：**整次拦住**自动同步——不猜成 me/other、也不偷偷丢掉以后继续保存；
  上一份已成功保存的聊天原样保留，等 unknown 消失后自动恢复。
- 过滤后没有 me / other → `waitingForChat`，不写空 payload、不覆盖旧聊天。
- 正式 JSON 契约完全不变：`format/version/updatedAt/messages[{role: me|other, text}]`；
  geometry / confidence / fingerprint / generation 都不进文件。
- `updatedAt` = 本次真正写入的时刻（键盘 30 分钟旧内容提示语义保持正确）。

## Fingerprint / debounce / 并发

- 指纹：按顺序拼 `role|text` 后取 **SHA-256**（deterministic，绝不用带随机 seed 的 `Hasher`），
  只用于内存比较。条数相同但正文变化、正文相同但角色变化都会重新同步。
- debounce `1.5s`：时间线每次更新都会重排；窗口内 `A → A+B → A+B+C` 最终只写 `A+B+C`。
- 最低写入间隔 `2s`：和 debounce 一起取较大值，避免频繁原子替换。
- 排队时保存的是**冻结快照**，不是会继续变化的时间线引用。
- 同一时刻最多一个 `SharedChatStore.save` 在飞；期间到来的更新排到下一次，写完再决定。
- 相同指纹不再写；同一份失败内容也不会每个 tick 疯狂重试（等内容变化或用户明确重开）。

## 代际与生命周期

- 自动同步绑定 capture generation：Stop → Start 之后旧 session 的排队任务与迟到回报都不能写进新 session。
- Stop：取消排队 + 回到关闭；**不**删除已经共享成功的聊天。
- 「清空实时聊天（不影响已共享聊天）」：取消排队，但不删 `latest_chat.json`；
  只要还开着，之后新的有效时间线可以重新同步。

## 人工确认优先

阶段 12C 的「整理当前实时聊天 → 人工修正 → 保存给狗头军师」**优先级最高**：
人工保存**成功**之后立刻 `pausedAfterManualSave`，取消所有 pending 自动同步；
此后时间线怎么变都不会覆盖人工结果，必须用户再次主动开启才恢复。
人工保存**失败**不会触发这个暂停（失败只报错）。

## 测试

`tools/LiveChatAutoSyncCheck`（CI 的 `Live chat auto sync contract`，注入时钟 + 临时容器，不联网）覆盖：
默认关闭、新 session 重新授权、开启后才同步、没有聊天 / 只有 system 不写、unknown 整次拦住且不猜不丢、
payload 只有 me/other 且顺序正文角色保持、`updatedAt` 用写入时刻、第一次有效时间线产生一次 scheduled、
debounce 窗口内连续变化只写最后一份、相同内容 20 次更新不重复写、条数相同正文变化 / 正文相同角色变化会重写、
一次在飞时不并发、在飞期间的更新最终会写入、成功更新指纹/时间/条数、失败进 failed、
同一失败内容不疯狂重试、失败后旧聊天仍可读、关闭 / Stop 取消排队并回到关闭、清空实时聊天不删共享聊天、
代际隔离（排队与迟到回报）、人工保存成功进入暂停并防覆盖、明确重开才恢复、
不写偏好设置与开关不持久化、正式 JSON 不带 geometry/confidence/fingerprint/generation，
以及源码级检查（不碰 AI、键盘上下文、输入代理、人物记忆）。

**阶段 12D 动态聊天自动同步 → SharedChatStore 尚待真机验收。**

## 真机验收步骤

1. 重签安装新 IPA → 主 App →「动态识别测试」→ 开始动态识别 → 系统界面选**整屏**
2. 确认「自动同步给狗头军师」**默认关闭** → 主动开启
3. 切到官方微信测试聊天，让几条明显左 / 右的消息出现，保持几秒
4. **不回主 App 整理/保存**，直接调出狗头军师键盘 →「读取识别聊天」
5. 确认已经能读到刚才自动识别并同步的聊天；确认没有自动 AI、没有自动插入或发送
6. 让微信再出现一条新消息，等几秒，键盘再「读取识别聊天」→ 确认新消息已进入
7. 构造一条被识别为「未确定」的消息：确认主 App 状态变成「因未确定消息暂停」，
   且键盘读到的仍是上一份成功结果（不会收到偷偷删掉 unknown 的残缺版本）
8. 回主 App「整理实时聊天」→ 人工修正 → 手动保存：确认自动同步显示「人工确认保存后已暂停」
9. 继续让时间线变化：确认人工修正版本没有被自动覆盖；主动重新开启后才允许继续覆盖
10. Stop 动态识别 → 确认下一次 Start 自动同步又默认关闭
