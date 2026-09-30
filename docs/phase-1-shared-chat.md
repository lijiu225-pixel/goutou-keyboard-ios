# 第一阶段：共享聊天数据通信

本阶段只实现 App Group 数据层与人工通信自测入口。屏幕捕获、OCR、聊天去重、AI 接入均未开始。

## 文件与行为

- `Shared/ChatSnapshot.swift`：统一消息角色、文本、时间及快照；默认 30 秒过期，时钟回拨超过 5 秒也视为过期。
- `Shared/SharedChatStore.swift`：读写、清空 App Group 根目录的 `latest_chat.json`，时间统一用 Unix 毫秒；原子替换，iOS 完整文件保护；缺少容器报错，缺少文件返回 nil，损坏 JSON 报错。不会退回各自沙盒而假装通信成功。
- `Shared/ChatSharingStatus.swift`：供两端显示条数和过期状态；每次从磁盘读取，不打印内容。
- `App/App.entitlements`、`Keyboard/Keyboard.entitlements`、`project.yml`：两端共享 `group.com.example.goutouinput.shared`，同一份 Shared 源码编入两个 Target。
- `App/SharedChatTestSection.swift`、`App/ContentView.swift`：主动写入两条固定示例，刷新、清空与最后写入时间。
- `Keyboard/GoutouPanelView.swift`、`Keyboard/KeyboardViewController.swift`：每次打开军师面板刷新共享缓存状态；不把示例导入现有上下文，不调用 AI，不插入消息。
- `tools/SharedChatCheck/main.swift`、`.github/workflows/build-ios.yml`：加入独立读写实例、中文角色和日期往返、替换、过期、损坏数据、清空与容器不可用检查；保留原九键回归及 Debug/Release 构建。
- `tools/check-swift-braces.py`：纳入新源码。括号检查不等于编译验证。

原有 API 配置剪贴板通道、人物记忆、九键引擎、候选词、英文数字符号输入路径和回复插入行为保持原实现。

## 构建与签名

需要在同一 Apple 开发团队下注册该 App Group，并为主 App 与键盘的 App ID 启用它；两份描述文件都要包含此组。修改 Bundle ID 时，也要同步修改两个 entitlement 与 `SharedChatStore.groupIdentifier`。

现有未签名 IPA 可用于编译产物检查；侧载工具重签后若移除/不支持 App Group 权限，通信会显示不可用。投屏连通或键盘安装成功不是共享容器有效的证据。

本机为 Windows，没有 swiftc、XcodeGen 或 xcodebuild。本阶段 Swift 行为测试和 iOS 编译尚未执行。后续通过已有 macOS Actions 工作流运行。不能在未通过构建与真机通信前宣称第一阶段验收完成。

macOS 本地行为测试：

```sh
swiftc -swift-version 5 Shared/ChatSnapshot.swift Shared/SharedChatStore.swift tools/SharedChatCheck/main.swift -o /tmp/sharedchatcheck
/tmp/sharedchatcheck
```

## 真机验收

1. 安装包含本阶段代码且正确签名的构建，键盘开启“允许完全访问”。
2. 主 App“共享聊天通信测试”点“写入示例聊天”，主 App 显示 2 条、新鲜、最后写入时间。
3. 在自测输入框切换到自定义键盘，打开“军师”面板，应显示“共享聊天：2 条（新鲜）”。
4. 等 31 秒，退出并重新打开军师面板，应显示过期。
5. 主 App 清空共享聊天，重新打开面板，应显示暂无缓存。再次清空不报错。
6. 关闭完全访问，重新打开面板显示权限提示，键盘普通输入仍可用。
7. 回归普通拼音/九键候选、英文、数字、符号、删除、换行；确保示例没有自动写进输入框，没有自动发送。

两端同时操作采用整份快照替换；不做多写者消息合并。后续识别模块是正常生产写入者，清空与写入并发时以最后完成的操作为准。
