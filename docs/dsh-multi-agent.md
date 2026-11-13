# DeepSeek Harness：Agent Teams 与 Superagent

LoongPass 通过官方 Magpie 向 DeepSeek Harness 提供已授权账号的模型。父 agent、子 agent 和后台 worker 使用 DSH 的模型配置；LoongPass 无需另外创建团队。

```text
DSH 父会话 / 子会话 / Superagent worker
                 ↓
Magpie：模型路由、原生分组、协议转换、推理恢复
                 ↓
LoongPass：逐账号授权、本机服务、原生供应方宿主
```

Agent Teams 是 DSH 的共享任务板与子 agent 协作能力。`dsh-superagent-prototype` 是另一套基于 DSH 的 GitHub / 飞书任务系统；其维护者明确将其标为研究原型，未宣称生产可用。两者可以消费同一个 Magpie 模型来源，但启用 Teams 不会自动部署 Superagent。[Agent Teams 文档](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/team/agent-team/README.md)、[Superagent 说明](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/main/README.md)

## 连接 Agent Teams

1. 在 LoongPass 保存账号，在「模型服务」启用相应账号并打开本机服务，点击「连接 Magpie」。
2. 在 Magpie 的 DeepSeek Harness 入口选择 LoongPass 模型或已有原生分组。保持 LoongPass 和 Magpie 网关运行。先在 DSH 新会话确认普通文本及终端工具调用成功。
3. 在 DSH 根会话的模型 / 推理菜单开启 **Use Agent Teams**，然后要求父 agent 拆分任务、启动子 agent 并使用任务板跟踪完成状态。
4. 若为子 agent 指定不同模型，在 DSH 的子 agent 模型设置中启用选择并配置允许的模型。模型 ID、协议、上下文与推理档位以 Magpie 生成的目录为准，不将显示名称当成模型 ID。

DSH 新建会话默认不开启 Teams；保存后的会话选择会在恢复时保留。需要让一个 headless profile 的新根会话默认开启时，可在它自己的 patch 列表中合入：

```yaml
- id: agent-team
  config:
    defaultEnabled: true
```

这不改变已有会话的选择。DSH 的 `config` 覆盖整个对应配置行；已有自定义字段需要保留，不要用示例替换完整 profile。[官方模式配置](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/team/agent-team/README.md)

Teams 成员共享 checkout。任务板中的文件提示只会警告冲突，不提供文件锁；并发写代码前仍需明确文件归属或使用独立 worktree。停止一个子 agent 不会自动释放其任务所有权，按 DSH 的任务工具处理。[任务与中断语义](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/team/agent-team/README.md)

## 为 Superagent 提供模型

按 [Superagent 官方部署指南](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/main/docs/006-deployment.md) 准备独立的 `superagent` Web profile，并按它当前的 `package.json` 核对 DSH 兼容范围。不要直接把某个桌面 RC 版本视作原型兼容性证明。

在该 profile 的模型管理页面确认 Magpie 提供方已经出现，选择 LoongPass 模型作为默认模型。Magpie 原生集成识别 DSH 的各 profile 并同步自己的模型来源；若模型未出现，先检查 Magpie 的 Harness 接入状态、双方是否使用同一个 `DSH_HOME`，以及 LoongPass 服务是否运行。不要拿 Desktop 的整份配置覆盖 Superagent 的插件与运行配置。[Magpie DSH 集成](https://github.com/yetone/magpie/blob/main/internal/agent/dsh.go)

Superagent 默认使用所在 profile 的默认模型；其 **Eval** 和 **Execution** 设置可分别指定模型。这样评估与 worker 都可使用 LoongPass 来源或 Magpie 原生分组。任务并发由 Superagent 的 `maxWorkers` 控制，实际可用并发还受账号与上游限制；增加 worker 数不会增加账号额度。[模型与执行配置](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/main/docs/006-deployment.md)

本次交付提供模型接入路径与指南，不创建监听仓库、GitHub 机器人身份、飞书机器人或常驻服务。这些需要在 Superagent 自己的 Sources / Policy / Execution 中独立配置。其 worker 以运行它的系统用户权限工作，上游推荐用专用系统账号隔离凭据。新建 profile 的 `--from-default-profile` 会替换已有 profile，升级时不要重复执行。[安装与隔离边界](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/main/docs/006-deployment.md)

## 网络与排查

- LoongPass 本机服务使用 `127.0.0.1:3426`，默认 Magpie 网关使用 `127.0.0.1:3425`。DSH 连接 Magpie，由 Magpie 使用 LoongPass 的逐账号授权。
- 从桌面启动时，LoongPass 原生宿主读取系统手动 HTTP/HTTPS 代理；显式代理环境变量优先。本机地址绕过代理。修改系统代理后重启 LoongPass。PAC 或仅 SOCKS 的设置需要先提供可用的 HTTP 代理端点。
- 若普通请求也超时，先检查代理与上游网络。只有模型目录加载成功，不能证明实际模型请求成功；无需为此重复登录账号。
- 遇到 429 时查看账号 / 上游并发与额度，降低活跃 worker 数。断流后的推理恢复归 Magpie 原生策略，可能额外消耗调用额度。
- 模型选择错误或工具不可用时，先核对当前模型是否支持工具及 DSH profile 是否加载了相应能力。LoongPass 不改写 DSH system prompt 或团队消息。

## 上游能力边界

| 项目 | 本链路职责 |
| --- | --- |
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) | 原生子 agent、Teams 任务板、会话恢复与模型配置 |
| [dsh-superagent-prototype](https://github.com/deepseek-ai/dsh-superagent-prototype) | 基于 DSH 的后台任务研究原型，消费 profile 模型 |
| [Magpie](https://github.com/yetone/magpie) | LoongPass 原生插件接入、DSH 模型来源、路由与协议兼容 |
| [magpie-community/plugins](https://github.com/magpie-community/plugins) | 供应方原生授权、模型与调用；不负责 DSH 团队调度 |
| [dsh-providers-hub](https://github.com/iJetLi/dsh-providers-hub) | 另一种 DSH 提供方插件路径；LoongPass 本链路使用 Magpie，不叠加两套账号 owner |

实际通过的版本、模型、设备和场景以 [验收记录](verification/2026-11-14-dsh-multi-agent.md) 为准；Superagent 常驻任务、外部消息与 PR 交付不由 Teams 测试推导。
