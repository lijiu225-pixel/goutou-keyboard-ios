# 识别聊天：结构化结果 + 三条推荐回复

阶段 10 把阶段 9 的「一段分析文本」升级成正式契约：

```
聊天分析 + 对方语气/态度/意图 + 恰好 3 条推荐回复
```

本阶段三条回复**只展示**：不调用 `insertText`、不插入输入框、不自动发送、不写记忆、不落盘。

## JSON 契约

正式发给模型的格式（`RecognizedChatPrompt.systemPrompt(skill:)` = `GoutouSkill.md` 原文 +
阶段 10 最小约束，skill 原文不动、不复制第二份）：

```json
{"analysis": "聊天分析正文", "tone": "对方语气 / 态度 / 意图", "replies": ["回复一", "回复二", "回复三"]}
```

正式要求恰好 3 条，**不是**旧 manual 链路的 6～8 条。
`GoutouPrompt.systemPrompt(skill:)` 与它的 6～8 条契约一个字都没动，手动上下文分析、
推荐回复、记忆链路继续用它；两条链路各自独立。

## 结果模型

`Keyboard/RecognizedChatAnalysis.swift`：

- `RecognizedChatResult`：`analysis` / `tone` / `replies`，独立于旧 `GoutouResult`（headline + 6～8 条），
  避免语义混淆。
- 上限集中管理：`requiredReplies = 3`、`maxReplyLength = 300`、`maxToneLength = 200`，
  分析沿用 `GoutouAIClient.maxAnalysisLength = 2000`。
- `RecognizedChatResult.normalized(fields)`：宽容进、严格出——trim → 丢掉空白与纯标点 →
  丢掉与前面完全重复的 → 单条超长截断加省略号 → 不足 3 条有效回复直接失败
  （`.notEnoughReplies`），不用空串凑数、不复制同一条。缺 analysis 或 tone 报 `.incompleteResult`。
- `RecognizedChatAnalysisSession.complete` 复用同一套归一化做兜底，手写或脏值同样进不了 `success`。

## 解析策略

`GoutouAIClient.parseRecognizedChatFields(data:)` 只负责**宽容拆字段**：

- 和 `parseResponse` 共用同一套工具（代码围栏、括号配平切片、字段切片、`stripThinking`）；
- 字段名兼容 `analysis/分析/聊天分析/分析结果/relationship/关系/总结/summary/meaning`、
  `tone/attitude/intent/语气/态度/意图/对方状态/状态/mood`、
  `replies/responses/suggestions/推荐回复/话术/候选`；
- 认不出 JSON 时把整段正文当分析（缺 tone / 三条回复由归一化拦下，不会伪装成成功）；
- 空响应 / 只回思考 / 被截断沿用阶段 9 的 `GoutouAIError` 口径。

网络层没有第二套客户端：`send(request:parse:)` 继续被手动链路与识别聊天链路共用。

## UI

成功后在军师面板（沿用滚动区域，键盘高度不变）显示三段：

```
【聊天分析】 正文
【对方状态】 语气 / 态度 / 意图
【推荐回复】 ① … ② … ③ …
```

三条候选是**只读卡片**：没有任何点击动作，也不是「发送」按钮（阶段 11 才接插入）。
loading（正在分析…）、失败（人能看懂的原因）、重新分析、取消分析沿用阶段 9；
重新读取聊天或取消使用会清掉 analysis / tone / replies。

## 测试

`tools/RecognizedChatAnalysisCheck`（CI 的 `Recognized chat analysis contract`，不联网、不消耗 token）
覆盖：Active Context 才能分析、Prompt 只要求 analysis + tone + 恰好 3 条且不含 6～8、
旧 `GoutouPrompt` 仍保留 6～8 条契约、正常解析（analysis / tone / 三条 / 顺序）、
超过 3 条只取前 3、少于 3 条失败、空 / 纯空格 / 纯标点 / 完全重复被拒、
单条超长截断、代码围栏与 thinking / reasoning 容错、纯文本或缺字段不算成功、
loading 防重复、迟到响应不写回、重新读取与取消使用清结果、不写 UserDefaults 与文件。

模拟器 UIKit 回归 `testRecognizedChatAnalysisNeedsExplicitTap` 额外断言成功态出现
【聊天分析】【对方状态】【推荐回复】、恰好三张卡片、没有「发送」与「插入」，
并且渲染不产生任何面板动作。

**阶段 10 结构化分析与三条推荐回复尚待真机验收。**

## 真机验收（与阶段 11 一起做一次即可）

1. 重签安装新 IPA，确认键盘已开启完全访问
2. 主 App 保存一份**虚构**聊天 → 微信调出键盘 → 读取识别聊天 → 使用这份聊天
3. 点「分析这段聊天」→ 出现「正在分析…」→ 返回三段结果
4. 核对分析、对方状态、三条候选的内容与顺序；确认没有「发送」、点候选不会插入
5. 主 App 保存第二份聊天 → 键盘重新读取，确认上一份结果消失；分析新聊天看到新结果
6. 取消使用识别聊天，确认结果一起清掉
7. 打几行拼音 / 九键 / 数字 / 符号，确认输入法核心没受影响
