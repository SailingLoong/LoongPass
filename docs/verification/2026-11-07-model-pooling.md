# 五平台模型接入与账号池化验证

2026-11-07，macOS 实现并验证 MiniMax CN、Loomy、WorkBuddy CN、Qoder CN、
ZCode BigModel Start Plan 赠送模型。模型服务复用应用已保存账号的 owner，
没有另存平台授权，也没有运行参考插件或读取第三方客户端的账号文件。

## 实现与真实客户端

真实链路为 Claude Code 2.1.308 → 已安装 Magpie 0.1.3244 → LoongPass 原生
账号 owner/模型适配器 → 各平台官方推理入口。验收宿主使用生产服务、适配器、
原生账号文件与原生锁，只将临时本地调用密钥保存到仓外；不启动奖励定时任务。
工具测试使用只能回显标记的本机 MCP，核对实际调用一次、匹配回执及最终答案。

| 来源 | 本轮实现/模拟检查 | 原生 Mac 构建 | 真实客户端结果 | 真实账号数 |
| --- | --- | --- | --- | --- |
| MiniMax CN | 动态目录、原生 Messages、既有账号租约通过 | Universal 通过 | `MiniMax-M3` 文本、流式、完整工具闭环通过 | 1 |
| Loomy | 动态目录、原生 Chat、双授权头与 UTF-8 通过 | Universal 通过 | `spark-x2.6` 文本、流式、完整工具闭环通过 | 1 |
| WorkBuddy CN | 桌面动态目录、Messages/Chat 分派、稳定 Vault 身份通过 | Universal 通过 | `auto` 原生 Chat 文本、流式、完整工具闭环通过；两个账号均收到请求 | 2 |
| Qoder CN | COSY 签名/封装、厂商流、原生及 XML 工具通过 | Universal 通过 | `fast` 文本、流式、完整工具闭环通过 | 1 |
| ZCode BigModel 赠送 | 实时赠送权益、设备上下文、原生格式、耗尽不转付费通过 | Universal 通过 | `GLM-5.3-Flash` 文本、流式、完整工具闭环通过；两个账号均收到请求 | 2 |

合计七个不同的真实账号，五个平台各至少一个。每个平台的三项 Claude Code
测试都通过；每个平台四次生产适配器派发，均为 HTTP 200，包含工具结果后的
第二次模型调用。逐 key 定位到原保存账号，不按页面当前选中账号重新解释。
WorkBuddy 的 Claude Messages 分支本轮为模拟覆盖，真实调用为 `auto` 的 Chat 分支。

所有七个本地调用密钥在实际原生进程重启后保持一致，监听启用意图恢复。
旧 v1 连接保留原 key、账号、模型和根路径权限；目录、UI、导入链接及实际调用
使用同一范围，不能因新目录扩大旧 key 权限。已移除的旧模型不产生无效接入链接。
显式撤销或移除账号会取消正在等待响应头的请求；正常令牌轮换保留稳定绑定。

## Magpie 与客户端重发边界

Magpie 使用官方 provider/key/routing 入口，每个平台的其他账号 key 加入同一
来源的密钥列表。首次接入链接只导入一个账号，不能冒充整池一键导入。
配置为 `routing=rotate errors=pass patience=off`。按请求轮换，不在失败后
自动补发同一请求，也不把账号间额度折算成统一货币。

Claude Code 自身还有独立的重试和流式降级。启动前同时设置：

```sh
export CLAUDE_CODE_MAX_RETRIES=0
export CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
```

同时不要配置自动模型 fallback。这两个设置来自 [Claude Code 官方环境变量](https://code.claude.com/docs/en/env-vars)。
仅关闭普通重试时，实测半段 SSE 仍触发了一次非流式补发；不能只凭 Magpie
配置宣称客户端不重发。补齐两个原生设置后，实际 Claude Code 对 HTTP 502 与
半段 SSE 都仅发送一次并以失败退出。应用页面明确提示这些前提，不修改用户
全局客户端配置；其他客户端必须单独核对其重试行为。

`tool/model_pooling_magpie_probe.py` 在独立 XDG 配置和临时端口运行合成来源，
关闭账号发现，不修改现有来源或默认模型。已安装 0.1.3244 的探针验证：

- Messages/Chat 文本、SSE、工具声明转换与模型协议自动识别通过。
- 两 key 的六个独立请求各收到三次；专属模型只到达对应 key。
- Magpie HTTP 失败、半段流均单次发送；Claude Code 整链故障各单次发送。
- 共 17 个合成派发、零平台调用；临时 provider、配置与进程均已清理。

最初安装的 0.1.3101 因 `unknown field errors` 不满足前提，未创建测试来源。
早期官方 0.1.3244 候选的 15 次探针通过，随后安装版升级到同版并重新通过。
候选 SHA-256 `aed558f0849b73e9819ef2e29aae6466d24889ca5eba9721c1754f6b61635b81`；
多余候选二进制已回收。兼容性以实际能力探针为准，不维护外部版本名单。

## 官方额度与身份核对

账号 owner 查询官方余额并保留观察时间、单位和到期信息，推理租约始终使用该
保存账号的身份及设备上下文。私有验收记录保存各账号调用窗口前后的绝对值，
不提交真实余额、身份、设备 ID、调用密钥或原始认证响应。

- MiniMax 按官方 points 核对：到期分组与无已知到期余额逐位求和，均等于总剩余值；
  用十进制手工复算调用窗口前后差额，与减少的分组一致。
- ZCode 两账号均为有效且未耗尽的赠送模型桶，官方单位为 token；分别核对前后
  剩余绝对值、正扣减和相同到期时间。无赠送资格的另一个账号明确拒绝加入，
  不领取新权益，也不转付费 Coding Plan。
- Loomy、WorkBuddy、Qoder 的官方观测余额本轮未显示变化。精度或异步结算原因
  尚未归因，不能据此宣称调用免费或零扣费；逐请求账单与计价归因仍未验收。

## 检查与平台覆盖

整合远程 main 的账号余额刷新改动后，执行：

```sh
FLUTTER_BIN=/path/to/flutter python3 tool/check.py
python3 tool/model_pooling_magpie_probe.py --automatic-api --claude /path/to/claude --output /private/path/probe.json
FLUTTER_BIN=/path/to/flutter python3 tool/build_macos_release.py
```

完整检查退出 0：静态分析无问题，267 项 Flutter 测试及全部独立 Dart、平台协议、
原生 macOS 存储/授权检查通过。独立审查发现的 SSE 心跳/CRLF、正常 EOF 截断、
账号移除时响应头等待取消均经失败回归复现后修复。原生实测还定位并修复了旧
ZCode 注册迁移的 CAS 修订、共享 JSON UTF-8 编码和 WorkBuddy 桌面版本/目录契约。
WorkBuddy 读取已安装官方客户端的公开版本元数据，保留 LoongPass 标识，未移植
隐藏客户端或修改用户提示词的绕行代码。

构建复用机器级锁与原生缓存；arm64、x86_64 三项主二进制及签名完整性检查通过，
不允许 release 调试附加。正式候选在 Apple Silicon Mac 启动，模型来源菜单、
两个 WorkBuddy 保存账号的选择及页面布局通过人工可见验收；下拉框在未选择时
显示占位文字，打开后实际账号可见。Intel 与 Windows 真机未测。
这是源码候选验收，不表示创建了新的 GitHub Release 或自动更新发行包。

本轮只覆盖表中实际模型及短对话。各来源其他模型、长时间静默流、可选采样参数、
强制工具选择和跨账号并行吞吐不从此次结果自动推导。MiniMax 国际、Qoder 国际、
TRAE 和 Z.AI 不属于这五平台推理验收；LobsterAI 仍按既有决定停止接入。
