LoongPass 1.0.1-beta.41

- 补齐 DeepSeek Harness Agent Teams 与 Superagent 的模型接入指南：父子会话共用 LoongPass 授权来源，模型选择与团队协作由 DSH 负责，路由和协议转换由 Magpie 负责。
- 修复从桌面启动后原生插件宿主遗漏系统代理、导致模型调用超时的问题。
- 在启动 Bun 前按 Magpie 原生约定传递代理设置，保留显式代理、绕过列表和本机直连，避免隐式代理抢占宿主的请求路由。

接入与范围

在 LoongPass 启用模型账号并连接 Magpie，再在 DSH 根会话选择「Use Agent Teams」。子 agent 可按 DSH 允许的模型列表选择不同模型。详见 [接入指南](https://github.com/SailingLoong/LoongPass/blob/v1.0.1-beta.41/docs/dsh-multi-agent.md) 与 [验收范围](https://github.com/SailingLoong/LoongPass/blob/v1.0.1-beta.41/docs/verification/2026-11-14-dsh-multi-agent.md)。

已在 macOS Apple Silicon 上通过 WorkBuddy DeepSeek 与 MiniMax 的双子 agent 并行、真实工具调用、任务板完成和会话恢复验收。自动检查包括 305 项原生运行时测试和 286 项 Flutter 测试；Windows / Intel 真机模型调用仍需单独验收。

Superagent 仍是上游研究原型；本版提供独立 profile 的模型接入路径，不含 GitHub / 飞书机器人与常驻服务部署。模型调用沿用 Magpie 原生恢复策略，恢复可能额外消耗额度。

系统手动 HTTP/HTTPS 代理在 LoongPass 启动时读取，修改后需重启。PAC 或仅 SOCKS 的设置需要先提供 HTTP 代理端点。

安装与升级

macOS 使用 LoongPass-macOS-universal.zip。Windows 日常使用 LoongPass-Windows-x64-Setup.exe，便携使用 LoongPass-Windows-x64.zip。应用内更新需开启「接收 Beta 版更新」。升级保留本机账号与领取记录。

本版为 Beta。macOS 使用本地签名，Windows 尚未配置 Authenticode 发布者签名；原生更新器验证 Ed25519 发布签名。请从官网或本仓库 Release 下载并核对 SHA256SUMS 与 SOURCE_COMMIT。
