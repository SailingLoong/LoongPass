LoongPass 1.0.1-beta.43

- 「模型连接」新增连接检查，分别说明 Magpie 命令是否可用、网关是否可达，以及所选账号的授权记录是否已保存，并给出对应操作。
- 连接 Magpie 后自动检查；打开页面不会启动检查。更换账号、重新授权或关闭服务后，旧结果会失效。
- 应用内提供 DeepSeek Harness Agent Teams 的接入步骤与完整指南入口，继续由 Magpie 管理模型路由、DSH 管理团队与会话。
- 保留 Beta 42 的桌面界面、原有账号、完整模型目录、签到与社区插件能力。

测试范围

连接检查不发送模型推理请求，授权记录存在不代表当前凭据有效或 Teams 已完成任务。Superagent 常驻任务仍需在上游独立配置。模拟、构建和实际安装的验收范围见仓库 docs/verification/2026-11-14-dsh-onboarding.md；Windows / Intel 真机调用另行验收。

安装与升级

macOS 使用 LoongPass-macOS-universal.zip。Windows 日常使用 LoongPass-Windows-x64-Setup.exe，便携使用 LoongPass-Windows-x64.zip。应用内在「设置」开启「接收 Beta 版更新」后检查更新。升级保留本机账号、设置与领取记录。

本版为 Beta。macOS 使用本地签名，Windows 尚未配置 Authenticode 发布者签名；原生更新器验证 Ed25519 发布签名。请从官网或本仓库 Release 下载并核对 SHA256SUMS 与 SOURCE_COMMIT。
