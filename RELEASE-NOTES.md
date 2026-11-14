LoongPass 1.0.1-beta.42

- 重新整理桌面导航、字体层级、按钮大小与布局，账号、模型连接、最近领取和设置入口更清楚。
- 账号列表保留可见的切换操作；详情就地打开，集中展示精确余额、查询时间、积分到期批次与待处理状态。
- 简化官方授权、账号恢复和设置流程，完整模型目录可展开；支持深色模式、窄窗口及大字号。
- 保留既有平台与地区、Magpie 与社区插件、授权方式、签到核验、账号维护、邀请码、客户端切换和更新功能。
- 包含 beta 41 的 DSH Agent Teams / Superagent 接入及系统代理修复。

测试范围

本版重点测试整套 UI 的日常使用、深色模式和窗口缩放。界面自动检查使用演示账号；新官方授权、真实领取、模型调用和客户端切换需分别按实际平台验证。此前功能验收仍见仓库 docs/verification，不把界面检查等同于真账号验收。

安装与升级

macOS 使用 LoongPass-macOS-universal.zip。Windows 日常使用 LoongPass-Windows-x64-Setup.exe，便携使用 LoongPass-Windows-x64.zip。应用内在「设置」开启「接收 Beta 版更新」后检查更新。升级保留本机账号、设置与领取记录。

本版为 Beta。macOS 使用本地签名，Windows 尚未配置 Authenticode 发布者签名；原生更新器验证 Ed25519 发布签名。请从官网或本仓库 Release 下载并核对 SHA256SUMS 与 SOURCE_COMMIT。
