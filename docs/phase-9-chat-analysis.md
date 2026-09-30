# 识别聊天 → 用户主动分析 → 一份聊天分析

阶段 9 只做一条链路：`ActiveRecognizedChatContext` → 用户点「分析这段聊天」→ 现有 AI 网络层 →
在军师面板显示**一份聊天分析**。不生成推荐回复、不插入输入框、不自动发送、不写人物记忆、
不做动态读屏；AI 接入到此为止，回复与插入留给后续阶段。

## 复用的网络层

没有第二套 HTTP 客户端。`GoutouAIClient` 里原本内联的网络骨架抽成了私有的 `send(request:parse:)`，
`analyze`（手动上下文 + 推荐回复 + 记忆链路）与新的 `analyzeChat` 都走它，
URL 组装、`URLSession`、60 秒超时、取消、HTTP 错误、宽容 JSON 工具、`stripThinking` 全部共用。
`analyze` 的签名和行为没有变化。

新增的只有两件事：

- `parseAnalysisResponse(data:)`：取「一份分析」。先看 `analysis`，兼容旧格式的
  `relationship` / `总结` / `meaning` 等字段，认不出 JSON 就把正文当分析；只要思考没正文按旧规则报错，
  空响应报 `.empty`，超过 2000 字截断加省略号。
- `analyzeChat(...)`：同一条网络骨架，解析成分析文本。

## Prompt：只给阶段 9 用

`GoutouPrompt.systemPrompt(skill:)`（军师人格 + 6～8 条话术的 JSON 契约）**一个字都没动**，
手动上下文分析、推荐回复、`lastResult`、记忆链路继续用它。

阶段 9 单独用 `RecognizedChatPrompt`：

- `systemPrompt(skill:)` = **原来的 `GoutouSkill.md` 原文** + 一段最小任务约束
  （只分析这段聊天、归属已人工确认不要重判、保持顺序、不写人设记忆与人物档案、
  不输出待发送的句子、只返回 `{"analysis": "…"}`）。
  约束里明确写着覆盖上面关于候选话术与回复条数的要求，所以不再要求 `replies`。
- `userMessage(messages:)` 按原顺序摊成 `我：…` / `对方：…`，角色与正文一个字不改；
  超过剪贴板契约上限（条数 / 单条 / 总长）时返回 nil，不截断、不 force unwrap。

API Key 沿用 `GoutouConfig.isReady` 的既有语义（baseURL + model 即算配置完整），
不因为阶段 9 强制要求 Key——无鉴权的本地 OpenAI 兼容端点仍然可用；
远程服务要 Key 时由 HTTP 401 / 403 给出友好提示。

## 状态机

`Keyboard/RecognizedChatAnalysis.swift`（纯 Foundation、不联网）：

- `RecognizedChatAnalysisState`：`idle` / `loading` / `success(String)` / `failure(Error)`，四态互斥，
  旧结果不会和新加载、错误文本混在一起。
- `RecognizedChatAnalysisSession.begin(hasFullAccess:config:skillAvailable:context:)`：
  所有准入判断都在这里——正在跑 → `.alreadyRunning`（不动状态、不发第二次）、
  没完全访问 → `.noFullAccess`、配置不完整 → `.notConfigured`、人格缺失 → `.missingSkill`、
  没有 Active Context（只有预览）→ `.noActiveContext`；全过才 `generation += 1` 并进入 `loading`。
- `complete(generation:result:)`：代际号对不上就一个字都不写。
- `invalidate()`：上下文变化（读到新聊天 / 取消使用 / 读取失败）→ 清结果并在途作废。
- `cancelInFlight()`：面板收起 → 在途作废，已有分析保留。

控制器只在 `.analyzeRecognizedChat` 分支里发请求，这是阶段 9 唯一会联网的地方。
DEBUG 日志只打印消息条数，不打印 Prompt、正文或 Key。

## 测试

`tools/RecognizedChatAnalysisCheck`（CI 的 `Recognized chat analysis contract`，不联网、不消耗 token）覆盖：
只有预览不能分析、读取与使用不触发请求、一次点击只发一次、分析中重复点击被挡、
成功 / 失败 / 空响应、上下文变化清旧结果、A 迟到返回不得写回新上下文、
请求里的条数/正文/归属/顺序、阶段 9 Prompt 不含候选话术或回复条数要求、
旧 `GoutouPrompt` 仍保留 replies 与 6～8 条契约、请求体与 Prompt 不含 UI 文案 / updatedAt /
App Group / Bundle ID / 沙盒路径、不写 UserDefaults 与文件；`buildURLRequest` 组装的请求体
也在这里逐项检查（只组装，不发送）。

模拟器 UIKit 回归 `testRecognizedChatAnalysisNeedsExplicitTap` 断言：读取不发分析动作、
点「分析这段聊天」只发一个 `.analyzeRecognizedChat`、loading / success / failure 三态文案、
成功时不出现推荐回复与插入按钮。

**阶段 9 AI 分析链路尚待真机验收。**

## 真机验收

1. 重签安装新 IPA，确认键盘已开启完全访问
2. 主 App 保存一份**虚构**测试聊天 → 微信调出键盘
3. 「读取识别聊天」→「使用这份聊天」，确认此时**没有**自动发起 AI 请求
4. 点「分析这段聊天」→ 出现「正在分析…」→ 返回一份聊天分析
5. 确认没有推荐回复、没有自动插入输入框
6. 主 App 保存第二份聊天 → 键盘重新「读取识别聊天」，确认上一份分析立即消失
7. 分析新聊天，确认显示的是新结果
8. 「取消使用识别聊天」，确认 Active Context 与分析一起清掉
9. 打几行拼音 / 九键 / 数字 / 符号，确认输入法核心没受影响
