# DSH 应用内接入与诊断验收

## 交付范围

Beta 43 在 Beta 42 的 Flutter / Forui 界面上增加显式连接检查与 DSH Teams 指引。服务与账号仍由 PluginModelService 拥有；ModelConnection 管理连接操作、诊断快照和失效，MagpieConnection 适配官方 CLI。模型路由、恢复与 DSH 配置继续由上游拥有。

诊断只检查命令发现、网关可达与 LoongPass 授权记录。插件关闭、加载失败或来源被替换时，Magpie 可能保留旧的 provider / account 缓存；本实现要求当前插件启用、成功加载并声明对应提供方，才将账号 ID 作为有效检查证据。未知格式保持未确认，不展示原始输出或凭据。

## 已完成的检查

- 仓库完整 `tool/check.py` 通过，包括 305 项原生运行时测试、291 项 Flutter 测试、Dart 分析和 macOS 原生检查。独立评审后增加缓存来源与关闭生命周期测试，并通过全部受影响的专项测试和 Dart 分析。
- 覆盖命令缺失、空插件列表、未登录、部分账号、未知格式、网关不可达、重复操作、检查期间账号或服务变化、关闭后不启动后续诊断。
- 组件验证页面打开与重建不启动 CLI、失败后可重新检查、原有模型与付费权益说明仍可展开、指南通过现有原生 HTTPS 打开接口。
- 实际 Flutter 渲染检查 1024×768 常规字号和 480×800 双倍字号，均覆盖浅色与深色；使用原有 Forui 组件与 Inter / Source Han Sans 字体。
- macOS Apple Silicon 上调用官方安装版 Magpie，实际识别当前网关未运行，并从成功加载的 LoongPass 插件读取授权记录。检查未发送模型推理请求。

## 验收边界

授权记录存在不证明凭据当前有效、模型调用成功、DSH 当前会话已启用 Teams 或 Superagent 已部署。本阶段不修改供应方协议和 DSH profile；此前真实双模型 Team、工具与会话恢复验收见 [Beta 41 记录](2026-11-14-dsh-multi-agent.md)。Windows / Intel 真机诊断与调用仍需分别验收。

公开安装包、远程 main、实际安装界面及清理结果随本次发布核对，不能从上述本地检查推导。
