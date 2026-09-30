# 识别聊天 → 用户确认 → 临时上下文

阶段 8 只做一件事：把键盘里的识别聊天预览，在**用户主动点击**之后变成
「狗头军师临时识别聊天上下文」。本阶段不调用 AI、不改 Prompt、不生成回复、不插入输入框，
AI 接入留给阶段 9。

## 状态模型

`Keyboard/RecognizedChatContext.swift`（纯 Foundation，无 UIKit）：

- `RecognizedChatContext`：`messages`（结构化 `role` + `text`）、`updatedAt`、`messageCount`。
  **只活在键盘进程内存里**，不写 UserDefaults / App Group 新文件 / Keychain / 人物档案 / 人物记忆。
- `RecognizedChatSession`：`preview` → `usePreview()` → `cancelUse()` → `read()` 的状态机，
  对外只暴露 `status`（`notLoaded` / `previewing` / `inUse`）、`canUsePreview` 和 `errorMessage`。

状态机自己不持有文件或网络依赖，读取动作由控制器以闭包注入，所以规则可以脱离键盘测试。
UI 只显示状态、触发动作；`GoutouPanelSnapshot.activeRecognizedChat` 是唯一入口。

## 必须成立的三条规则

1. **读取 ≠ 使用**：`read` 成功只进入预览；必须先点「使用这份聊天」才 `inUse`。
2. **重新读取先作废旧上下文**：`read` 在任何文件 I/O 之前清掉旧 `preview` 和旧 `active`。
   上一次用着聊天 A，这一次读聊天 B 失败（文件已删 / JSON 损坏 / 版本不支持 / 无完全访问 /
   消息非法），结果必须是预览与活动上下文**都空**，绝不能留下偷偷生效的 A。
3. **取消使用 ≠ 删除共享聊天**：`cancelUse()` 只清 `active`，预览和 `latest_chat.json` 都不动。

30 分钟判定继续复用阶段 7 的 `SharedChatSnapshot.isOlderThanThirtyMinutes`（29:59 不提示、
30:00 不提示、30:01 提示），旧聊天仍然允许使用，不再实现第二套过期逻辑。

## UI 三态

- **A 尚未读取**：只显示「尚未读取识别聊天。」或具体错误。
- **B 已读取，还没使用**：「已读取 N 条聊天」+「使用这份聊天」按钮。
- **C 正在使用**：「已使用识别聊天 · N 条」+「取消使用识别聊天」按钮；主屏也显示同一行状态。

沿用原有面板和滚动区域，键盘高度不变（302），聊天很长就在面板里滚。

## 测试

`tools/RecognizedChatContextCheck`（CI 的 `Recognized chat context state contract`）用临时目录覆盖：
读取不等于使用、使用后正文/归属/顺序/时间不变、第二次保存替换、取消使用保留预览与文件、
聊天 A 活动时读取 B 先失效、文件不存在 / JSON 损坏 / 版本不支持 / 无完全访问都清空两个状态、
空聊天与非法聊天进不了活动上下文、30 分钟三个边界、使用与取消不往容器多写文件。

「使用这份聊天不得联网」由结构保证：状态机不持有网络客户端，控制器 `.useRecognizedChat`
分支只改状态；模拟器 UIKit 回归同时断言点击该按钮只发出一个 `.useRecognizedChat` 动作，
不会出现 `.analyze`。这里不为了这一条改造网络层。

临时目录测试不证明真机签名权限。**阶段 8 临时上下文状态尚待真机验收。**

## 真机验收

1. 重签安装新 IPA → 主 App 保存一份聊天
2. 微信调出键盘 → 「读取识别聊天」→ 看到预览，且**还没有**显示「正在使用」
3. 点「使用这份聊天」→ 显示「已使用识别聊天 · N 条」
4. 点「取消使用识别聊天」→ 预览还在，「正在使用」消失
5. 再点「使用这份聊天」→ 恢复 active
6. 主 App 保存第二份不同聊天 → 键盘点「读取识别聊天」→ 旧 active 立即失效，只看到新预览
7. 再点「使用这份聊天」才让新聊天生效
8. 主 App 清除共享聊天 → 键盘点「读取识别聊天」→ 旧预览与旧 active 都消失，提示尚未保存
