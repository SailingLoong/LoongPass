LoongPass 1.0.1-beta.44

- 修复 macOS 在账号页下拉框选择 WorkBuddy 国内版等选项时，可能因无障碍桥接的 startEditing 异常退出的问题。
- 统一修正平台、排序、分页、设置和授权选择器的无障碍语义，保留原有样式、焦点、键盘与屏幕阅读器操作。
- 增加真实 macOS 无障碍桥接回归检查，发布打包时验证连续切换选项。
- 保留 beta 43 的 DSH 接入引导、显式连接检查与诊断，以及现有 Magpie、社区插件、账号、签到、模型和客户端切换功能。

安装与升级

macOS 使用 LoongPass-macOS-universal.zip；Windows 使用安装版或便携包。旧版在设置中开启「接收 Beta 版更新」后选择「检查更新」。升级保留本机账号、设置与领取记录。

本版为 Beta。macOS 使用本地签名，Windows 尚未配置 Authenticode 发布者签名；原生更新器验证 Ed25519 发布签名。请从官网或本仓库 Release 下载并核对 SHA256SUMS 与 SOURCE_COMMIT。
