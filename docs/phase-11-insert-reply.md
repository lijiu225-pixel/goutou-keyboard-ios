# 推荐回复 → 用户点击 → 上屏

阶段 11 只做一件事：把【推荐回复】里的三条候选从只读卡片变成**可点击**的卡片，
点一下把**那一条原文**交给 `textDocumentProxy.insertText`。到此为止。

插入 ≠ 发送：本项目不做自动发送、不模拟回车、不加换行或空格、不清用户草稿、
不联网、不写记忆、不落盘。

## 插入数据流

```
RecognizedChatResult.replies[i]        （阶段 10 的当前结果）
   ↓  卡片标题显示「① 原文」，带出去的是原文本身
GoutouPanelAction.insertRecognizedReply(String)
   ↓  控制器：RecognizedReplyInsert.perform(reply, from: session) { textDocumentProxy.insertText($0) }
RecognizedChatAnalysisSession.replyToInsert(reply)   ← 只有当前 success 结果里逐字有这一条才返回它
   ↓  校验通过才写一次，写的就是同一个字符串
textDocumentProxy.insertText(reply)
```

序号只属于 UI（`①`/`②`/`③` 是卡片标题的一部分），**不进正文**。

## 为什么旧卡片插不进去

`replyToInsert(_:)` 只看**当前**状态：

- `idle` / `loading` / `failure` → nil；
- 读了新聊天、取消使用、重新分析进入 loading → `state` 已经不是那份 `success`，同样 nil；
- 传进来的文本必须与当前 `result.replies` 里某一条**逐字相同**（带序号、带空格、带换行、
  别份聊天的回复都不算）→ 否则 nil。

控制器用的是控制器手里的当前状态，不是渲染时的快照，所以「旧卡片 + 迟到的点击」也插不进去。
界面层只负责上报「用户点了哪一条」，`UITextDocumentProxy` 只出现在 `KeyboardViewController`。

## 插入之后

按最保守行为：不清结果、不重新分析、不生成下一轮、不发送，卡片继续留在面板里；
用户再主动点同一条可以再插一次（每次插入都对应一次明确点击，没有隐藏防抖）。
与手动军师链路的「插入后收起面板」不同——那里是关闭面板，这里是留在原地。

## 测试

`tools/RecognizedChatAnalysisCheck`（CI 的 `Recognized chat analysis contract`）用注入的写入闭包当 spy：
idle / loading / failure / 作废后 / 读新聊天后 / 取消使用后 / 重新分析 loading 时**一次都不写**；
成功之后点第 1/2/3 条分别写 `replies[0/1/2]`，写入字符串与原文逐字相等（无序号、无首尾空白、
无换行），一次点击只写一次；带序号/空格/换行的脏文本与别份聊天文本都不算；两次明确点击 = 两次插入；
插入过程不写文件也不写 UserDefaults。

模拟器 UIKit 回归 `testRecognizedChatReplyCardsInsertExactText`：idle / loading / failure 下没有任何候选卡片；
成功态恰好三张可点卡片；点 ① / ② / ③ 分别只发一个 `.insertRecognizedReply(replies[0/1/2])`，
且不产生任何分析动作；界面里没有「发送」。

**阶段 10 + 11 尚待真实 iPhone / 微信联合验收。**

## 联合真机验收步骤

1. 重签安装阶段 11 的 IPA，确认键盘已启用、完全访问已开启
2. 主 App 选一张聊天截图 → OCR → 人工修正正文与我 / 对方 → 「保存给狗头军师」
3. 打开官方微信，进一个**测试聊天**，调出狗头军师键盘
4. 「读取识别聊天」→ 核对条数 / 顺序 / 正文 / 归属 → 「使用这份聊天」（确认没有自动调 AI）
5. 「分析这段聊天」→ 出现「正在分析…」→ 显示【聊天分析】【对方状态】【推荐回复】恰好三条
6. 点第 1 条：文字进入微信输入框，微信**没有**自动发送；删掉后再测第 2、3 条，点哪条插哪条
7. 先在输入框手打「测试：」并把光标放到后面，再点一条候选：确认原有草稿没被清空
8. 正常测九键 / 拼音 / 数字 / 符号 / 删除 / 空格 / 回车，确认输入法核心正常
9. 主 App 保存另一份聊天 → 键盘重新读取：旧分析、旧对方状态、旧三条候选全部失效
10. 重新使用、重新分析，确认新聊天得到新结果
