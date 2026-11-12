LoongPass 1.0.1-beta.34

- 桌面界面采用 Forui 官方 Neutral Desktop 浅色、深色主题，统一导航、账号表格、登录表单、明细弹窗、模型服务和设置页面。
- 账号表格支持清晰的鼠标悬停与键盘焦点提示，修正到期文字颜色和较大文字下的输入框、行高，适配窄窗口及折叠侧栏。
- WorkBuddy、Qoder CN 支持配置邀请码，并从添加账号表单打开官方邀请注册入口。
- Qoder CN 原生插件更新到固定版本 0.2.64，改善额度耗尽后的模型账号选路。
- 使用 Flutter 3.47.9 / Dart 3.13.7。

安装与升级

macOS 使用 LoongPass-macOS-universal.zip。Windows 日常使用 LoongPass-Windows-x64-Setup.exe，便携使用 LoongPass-Windows-x64.zip。升级时保留本机账号目录，旧版授权存储会按现有迁移流程处理。

本版为 Beta。应用内更新需开启「接收 Beta 版更新」。macOS 仍使用本地签名，Windows 尚未配置 Authenticode 发布者签名；原生更新器继续验证 Ed25519 发布签名。请从官网或本仓库 Release 下载并核对 SHA256SUMS 与 SOURCE_COMMIT。

界面验收范围见 docs/verification/2026-11-09-forui-desktop.md。账号与原生模型运行时的验收记录见 VALIDATION.md 及 docs/verification/2026-11-09-native-runtime.md。辅助任务仅在应用运行期间执行，奖励资格及最终余额以平台官方结果为准。
