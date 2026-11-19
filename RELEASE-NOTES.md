LoongPass 1.0.3-beta.52

- 模型连接和 Magpie 统一使用模型厂商官网的 API ID。DeepSeek Flash 的各渠道别名合并为 `deepseek-flash`，请求仍使用所选账号在对应 App 中的原始模型 ID。
- Magpie 默认显示 Auto，可在模型连接中开启具体模型的单独显示，并按需搜索模型、调整 Auto 的候选顺序。修复窄窗口使用大字号时筛选按钮的溢出。
- Codex 在 macOS 和 Windows 支持原生账号切换。确认并等待官方客户端退出后，再切换账号和启动客户端。
- 修复升级后的 WorkBuddy 原生模型路由恢复和 Windows 本地桥接路径兼容问题。

安装与升级

macOS 使用 LoongPass-macOS-universal.zip。Windows 提供安装版和便携 ZIP。已安装用户可在设置中开启「接收 Beta 版更新」，然后选择「检查更新」。

macOS 使用本地签名，Windows 安装包使用 Ed25519 更新签名。安装包 SHA-256 和构建对应的源码提交见本页的 SHA256SUMS 与 SOURCE_COMMIT。
