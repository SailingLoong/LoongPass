# 统一模型路由验收

2026-11-08，按 Allen 确认的方向实现：Magpie 选择 LoongPass 的模型，LoongPass
在提供同模型的已连接平台与保存账号间选路，同一 session 优先留在原账号。
模型目录、账号权限和选路均有明确 owner，不在界面维护另一份模型/账号状态。

## 真实链路与结果

Claude Code 2.1.308 → 本机 Magpie（核对版本 0.1.3302）→ LoongPass 生产
ModelService、原生账号 owner 与适配器 → 官方推理接口。验收使用独立临时
Magpie/Claude 配置与本地调用密钥，不修改用户已有来源，不启动奖励定时任务。

最终完整原生轮次在运行时代码提交 `a96e301` 上执行。随后独立审查要求的原生
配置更新与多模态预检另有回归验证，不把文本验收推导为图片工具支持。

| LoongPass 模型 ID | 此轮实际请求到达 | 文本 | 流式 | 一次工具调用及结果回传 |
| --- | --- | --- | --- | --- |
| `qwen3.8-flash` | Loomy、Qoder CN | 通过 | 通过 | 通过 |
| `hy3` | WorkBuddy CN | 通过 | 通过 | 通过 |
| `deepseek-v4-flash` | WorkBuddy CN | 通过 | 通过 | 通过 |
| `glm-5.3-flash` | ZCode BigModel 赠送模型 | 通过 | 通过 | 通过 |
| `kimi-k3.1-pro` | Qoder CN 的 `kmodel_latest` | 通过 | 通过 | 通过 |
| `minimax-m3` | MiniMax CN | 通过 | 通过 | 通过 |
| `qoder-cn/fast` | Qoder CN 的独立 Fast 档位 | 通过 | 通过 | 通过 |

七项各四次生产适配器派发，合计 28 次，均收到 HTTP 200 并完整结束；每项的
本机 echo 工具恰好执行一次，模型收到匹配的工具结果并返回最终标记。每项工具
往返的两次请求均到达同一保存账号。Qwen 的不同会话实际分布到了两个平台。

本轮原生宿主加入了九个可用账号：MiniMax CN 一个、Loomy 一个、WorkBuddy CN
两个、Qoder CN 一个、ZCode 四个。另一个没有赠送资格的 ZCode 账号被排除，
没有领取新权益或转付费计划。目录包含 28 个条目，含明确命名空间隔离的档位；
该数量不表示 28 个不同底层模型均已逐项实测。

GLM-5.3-Flash 的目录来源为 Loomy、Qoder CN、ZCode；本表如实列出最终完整
轮次到达的平台，不把可发现的来源全部计成真实调用。之前轮次还观察到了 Qoder
的 GLM 文本请求。K3.1 的精确版本为官方目录中的 **Kimi-K3.1-Pro**。

## 统一来源、会话与权限

- `/v1/models`、`/v1/messages` 使用独立持久化的统一 key。旧账号 key 与旧 v1
  根路径保留原权限，不能访问整个池；重启不更换已有 key，显式重置会撤销旧 key。
- 平台适配器返回 `canonicalId`；路由层不维护模型系列名单。Qoder 的版本名称
  与 COSY 原生代号分开，发送时仍使用原代号。版本、日期、变体不互相替代；
  Auto、Fast、QoDuck 等无法核实底层模型的档位保持来源隔离。
- 只连接明确加入且启用的账号。可一次连接全部已保存账号；某账号没有资格不会
  阻止其他账号，持久化失败会明确报错。读取页面或目录不连接账号、不刷新或领取。
- 新会话在可用账号间分散；已有会话优先保留绑定，失败后只有后续独立请求可换路，
  换路后继续优先保留新账号。会话记录不保存对话，闲置六小时淘汰，最多 4096 项。
- Magpie 原生 CLI 的 `header.X-LoongPass-Session=${sessionId}:${subagentId}`
  传递会话标识；没有收到会话标识的直接请求按请求分散。Magpie 的原生解析仍决定
  不同客户端如何提供 session，本轮整链验证的客户端为 Claude Code。
- 首次连接使用 `provider add`；目录、地址或 key 变化使用 `provider set loongpass`。
  已安装 Magpie 的隔离配置实测确认更新后仍只有同一 `loongpass` 来源，旧 key 被
  替换，新模型与会话模板均保存。普通导入链接不支持模板，不能冒充完整统一配置。
- Magpie 配置 `errors=pass patience=off`；Claude Code 同时关闭普通重试和非流式
  fallback。一次未知结果不会重发，不把 LoongPass 单次发送等同于所有客户端都不重试。

## 协议与独立审查修复

统一入口在选路后衔接原生 Messages/Chat。合成与实际客户端回归覆盖系统提示词、
工具定义、参数与回执、UTF-8 分块、SSE 心跳、分片工具名/JSON、明确终止和截断失败。
token 验收逐项断言输入、输出、缓存读取的绝对计数，不只检查字段或比例。

真实验收发现并修复：

1. 一个统一来源不能为了逐模型测试重复添加同一地址/key；验收工具改为单一来源
   测多个模型，符合真实产品接入方式。
2. Claude Code 的自适应思考/effort 与保留全部历史的上下文策略需要正常转换。
   空 thinking signature 的工具后续轮不能被误拒绝；实际删改历史或不能表达的
   语义仍明确拒绝。参考 [Claude context editing](https://platform.claude.com/docs/en/build-with-claude/context-editing)
   与 [Chat API](https://developers.openai.com/api/reference/resources/chat)。
3. WorkBuddy 的生成中分块使用空 `finish_reason`；只有非空终止原因才是结束。
   对实际诊断字段形状增加失败回归，不把合法分块误判为截断。

一次独立全分支只读审查发现两项重要问题，均以失败回归复现并修复：

- 统一 key 轮换与目录更新必须更新原 Magpie 来源。增加显式更新命令与 UI，
  不创建第二个来源使旧客户端继续使用撤销的 key。
- Qoder 的原生字符串位置不能无声丢失图片工具结果。适配器增加纯请求预检，
  在选路前排除不能表达该内容的目标；直接账号入口也在网络发送前拒绝。回归
  覆盖 Messages 转换后实际构造 Qoder 请求，以及改选能保留内容的其他来源。

权限与取消回归还覆盖：旧 key、冲突凭据、撤销/禁用、注册生命周期、重启、
磁盘写入失败、真实 held HTTP 响应头等待中的账号撤销与统一 key 轮换，均只发送一次。

审查修复后重新执行 `FLUTTER_BIN=/path/to/flutter PUB_HOSTED_URL=https://pub.dev
python3 tool/check.py`，退出码 0：静态分析无问题，267 项 Flutter 测试、全部独立
Dart/协议检查及原生 macOS 存储、授权和进程检查通过。验收宿主另经 Dart 静态
分析。原生 Magpie 的 add/set 配置探针与前述七模型整链结果分别保存，不互相冒充。

## 额度、发行与覆盖边界

官方余额按原单位观察。MiniMax 的 points 在调用窗口前后均以十进制核对分组
合计与总剩余，并复算差额；不提交个人余额。逐请求账单与各平台计价归因没有由
本轮推导，不能把未显示变化的余额认定为免费或零扣费。

早期一次 ZCode 工具后续轮出现 SocketException，原请求失败退出且没有补发；
随后独立完整轮次的四次 GLM 调用均通过。失败记录与最终证据保存在仓外私有目录，
不把一次网络失败抹去，也不把单次成功当作长期网络稳定性保证。

本轮真实运行平台为 Apple Silicon macOS，具体为表中模型与短对话。其他模型、
长时间静默流、跨账号并行吞吐、视觉/图片工具、结构化输出、Windows/Intel 真机、
以及其他客户端仍分别验收。没有自动加入新的第三方平台，也未恢复 LobsterAI。
源码候选和真实调用通过不表示创建新的 GitHub Release 或自动更新包。
