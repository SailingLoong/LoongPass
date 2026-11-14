# 飞书与本机 DSH 接入验证

## 固定来源

- 官方 DeepSeek Harness 0.2.2-rc.2，macOS Apple Silicon。
- 社区 `dsh-lark-channel` 0.0.7，提交 `632807d9abafbb866a5e208a0298eff21c7856d1`，BSD-3-Clause。
- 飞书传输 SDK `@larksuite/channel` 0.4.1。
- 上游兼容补丁 SHA-256 为 `a304b06d517b4878d9cc1c8b3ff1c42c160f92078ecfee5abec4f6e08872a080`。原文件与补丁后文件校验保存在 `integrations/dsh-feishu/upstream.json`。

## 已验证行为

| 场景 | 方法与结果 |
| --- | --- |
| 原生插件安装 | 通过官方 DSH 插件管理器安装固定包，pnpm patchedDependencies 应用补丁。七个目标文件逐一匹配预期哈希，重复安装通过 |
| profile 配置 | 隔离目录测试与官方 `--dump-config` 核对 Teams、工作目录、模型、名单，保留已有 Magpie 行 |
| 两个子 agent | 实际 DSH 与实际 LoongPass／Magpie 推理，飞书边界采用内存传输。WorkBuddy DeepSeek-V4.1-Flash 和 MiniMax M3.1-Flash 各完成一个任务，并发重叠 10.768 秒 |
| 任务板与结果 | 父 agent 创建并核对两项完成任务，实际工具读取 `5050` 与 `42`，工具计算总和 `5092`，回复发到触发消息对应的频道 |
| 重启恢复 | 停止并重启 DSH，原聊天恢复同一 session，再读取任务板和文件，返回 `5092` |
| 活跃任务停止 | 模型启动等待中的工具，频道 `/stop` 触发原生取消，后续同会话请求正常返回 `STOP_RECOVERED` |
| 子 agent 审批 | 真实 Cordis 与上游测试 harness 分别加载补丁源码和发布入口，覆盖子孙审批、实际命令归属、跨 session 同 callId、允许、拒绝、重复点击、错误身份、跨聊天与无活根委派 |
| 原生工具审批 | 实际 DSH 根 agent 发起两次工具升级，内存频道回传卡片并分别允许一次、拒绝。原生日志记录 `allowed-once` 和 `rejected`，允许的文件内容逐字匹配，拒绝的文件不存在 |
| 默认子任务权限 | 实际 DSH 创建的两个子 agent 均记录委派策略 `never`，越权写入被原生拒绝，两个目标文件均未创建。审批适配保留该策略 |
| 后台代理 | launchd 与 systemd 配置生成保留已有标准代理环境变量，修正前后 probe 对照通过 |

两模型测试中的一次附带 stderr 重定向被 DSH 沙箱拒绝。计算与文件写入已完成，父 agent 随后通过工具重读两份结果和最终任务板，验证通过。

## 飞书租户验收

机器人身份与目标范围等待使用者绑定确认。真实飞书入站、回复及卡片点击仍待该步骤完成。

上游使用进程内消息去重缓存。跨重启重复事件去重和断线期间消息补拉没有保证。上述恢复检查覆盖会话历史与任务板。

配置和安装工具的回归在 macOS 运行。Windows 操作系统锁分支待 Windows 实机验证。

## 职责与实现

本仓的 Python 工具准备固定依赖和专用 profile。TypeScript 补丁修改上游频道的宿主接口适配，符合必要集成桥接的语言豁免。工具、权限、会话和 Teams 由 DSH 拥有，模型路由由 Magpie 拥有，账号授权由 LoongPass 拥有。
