# Magpie 与现有平台对齐验收

本轮从日常 Claude Code 的 `400 unsupported_content` 反查共享协议和所有现有
供应方设置。旧轮次的 `--bare`、自定义系统提示词和精简工具通过，不能代替默认
提示词、环境消息和 ToolSearch；旧记录已补充这一覆盖边界。

## 来源与分层

参考只读源码：Magpie `8f6298fb5e54e1e90b973856e5fb853ad553931a`，社区插件
`5db645541a79db17558f7a245e88efbd74b7c56d`。ZCode、WorkBuddy、Qoder、MiniMax、
TRAE、Loomy 都在同一个已有插件仓中，无需重复添加六个仓。
来源许可保留于 `MAGPIE-LICENSE.txt`、`MODEL-ADAPTERS-LICENSE.txt` 和第三方声明。

按已确认的两层归属实现：

- 共享 Magpie 接入：Messages/Chat 消息、工具加载/回执、思考/输出语义、计数、
  会话上下文、目录发布和本地调用权限。供应方不复制 Claude 转换。
- 供应方：实际授权、续期、目录事实、请求头、原生参数、流式封装、额度与拒绝分类，
  均由既有账号 owner 和对应适配器负责。

Magpie 在 LoongPass 内部选账号前已经选择协议。同一模型池包含原生 Chat 和
Messages 来源时，单纯配置两个地址会丢掉另一类可用账号，因此仍由统一边界在
选路后衔接协议。没有引入插件账号缓存或第二套授权 owner。

## 已修复的可观察行为

共享边界保留 `messages` 中的 system 环境消息，处理延迟工具定义、引用、移除
及图片回执；保留匹配工具结果后再归属图片。effort-only 辅助请求不会意外开启
思考，显式预算和 JSON Schema 输出按可表达语义转换。目录能力用于发送前预检：
已知强制思考来源不能接受关闭思考，已知无思考来源不能静默接受开启思考。
图片等不能表达的请求也在发送前拒绝或选择其他兼容来源。

统一和单账号接入都生成稳定的原生 `provider add/set` 命令，配置会话 header、
`errors=pass`、`patience=off`；普通导入链接不能携带这些设置。中立上下文将会话、
用户轮次、请求和 agent 标识交给供应方映射；账号之间隔离，不使用第一句文本
充当会话身份。供应方的规范化错误与 Retry-After 影响后续请求，不重发当前推理。

| 平台 | 修复范围 |
| --- | --- |
| WorkBuddy CN | 使用 cli 目录；从签名安装客户端读取真实 App/CLI 元数据；补齐工具/schema/思考与会话头；保存刷新授权并由 vault 续期；明确 token 拒绝反馈账号 owner |
| Qoder CN | 修正客户端 ID 与临时刷新错误分类；按目录处理思考/窗口/输出上限；保留任务生命周期；代码示例不当作工具调用；不支持的语义参数发送前拒绝；保留额度单位与错误分类 |
| MiniMax | 接受合法省略 scope；可选领取字段不阻断回执；保持会话、beta 与目录事实；额度拒绝规范化；明确账号 API/推理授权拒绝反馈 owner；未知领取通过只读状态恢复，保留原证据 |
| ZCode BigModel | 接受无歧义 plan-only 余额；显示与模型共享真实生效权益；明确限流可等待后续操作；领取前检查验证配置；映射会话/query/ToolSearch，不转付费套餐 |
| Loomy | 对齐思考档位与旧 DeepSeek 图片格式，保留现代模型图片形状、UTF-8 和双认证头 |
| TRAE CN | 核对现有授权、余额与单次领取边界，补齐已知到期字段别名；未宣称具备模型推理接入 |

额度与计数按绝对值验证。例如合成 Qoder 数据 `2,000,000 - 1,500,000 =
500,000 tokens`、`1,100 - 245 = 855 credits`，包余额 `10 - 2 = 8 credits`
与计划额度保持独立；TRAE `300 - 75 = 225 credits`。缓存计数分别断言普通输入、
缓存读取、缓存写入与输出，不只检查字段存在或倍率。

## 验证档位与保留边界

运行时源码提交为 `e5353c7b1ca546c4c068559ddc950f2d50535e63`，包含最新安全修复
基线 `4dc71ba`。使用官方 Flutter 3.47.8 / Dart 3.13.7：

- `FLUTTER_BIN=/path/to/flutter PUB_HOSTED_URL=https://pub.dev python3 tool/check.py`
  退出 0：静态分析、268 项 Flutter 测试、全部独立 Dart/Python/原生检查通过。
- 补充原生 WorkBuddy vault 验证、13 项 MiniMax 刷新预留/重启边界检查通过；
  独立审查曾复现的工具误执行、参数丢失、授权拒绝和周期日问题均重新复验。
- `tool/build_macos_release.py` 在共享锁下完成一次 Universal release 构建；
  主程序、App.framework 和 FlutterMacOS.framework 都包含 arm64/x86_64，
  release entitlement 不允许调试附加，深度签名检查通过。候选版本为 1.0.1/32。

### 默认 Claude 与生产入口

Claude Code 2.1.311 → 安装版 Magpie 0.1.3302 → 上述候选的生产 ModelService、
原生账号 owner 和适配器 → 官方推理接口。先退出旧 LoongPass 进程再启动候选，
没有并行运行第二个账号写入者。验收恢复的是已有账号与偏好；生产入口会按已有
设置恢复自动任务，本轮推理探针没有主动发起新的登录或领奖。

主轮次使用临时 Magpie/Claude 配置，保留 Claude 默认系统提示词和内建工具，
未使用 `--bare`、自定义系统提示词或精简工具集。MCP 仅配置受控 echo，工具轮次
强制先经 ToolSearch 加载再调用一次，随后核对返回标记。

| 模型 ID | 本轮实际到达的来源 | 默认文本 | ToolSearch → echo → 结果回传 |
| --- | --- | --- | --- |
| `deepseek-v4.1-flash` | Loomy、WorkBuddy CN | 通过 | 通过 |
| `deepseek-v4-flash-0731` | Loomy | 通过 | 通过 |
| `hy3` | WorkBuddy CN | 通过 | 通过 |
| `glm-5.3-flash` | ZCode BigModel 赠送模型 | 通过 | 通过 |
| `kimi-k3.1-pro` | Qoder CN、WorkBuddy CN | 通过 | 通过 |
| `minimax-m3` | MiniMax CN、MiniMax 国际 | 通过 | 通过 |
| `qwen3.8-flash` | Loomy、Qoder CN | 通过 | 通过 |
| `qoder-cn/fast` | Qoder CN 独立 Fast 档位 | 通过 | 通过 |

八项各四次流式 API 请求，共 32 次，均为 HTTP200 并完整结束；32 次都有 inline
system 环境消息和会话 header，16 次携带历史中的 tool_reference。每项 echo
恰好执行一次，最终标记匹配。此处按实际平台记录覆盖，不据目录账号数宣称逐个
账号都已实测，也不将发现的其他模型算作已通过。

随后使用已有用户 Claude 配置、默认提示词和内建工具，隔离 MCP 后再调用一次
`loongpass/deepseek-v4.1-flash`，成功返回指定标记。临时调用凭据已通过原生 CLI
移除；没有把用户所有其他 MCP 配置推导为本轮已验证。

当前统一目录为 27 项。旧 `deepseek-v4-flash` 已不在本轮来源目录，不将它自动
改名为 V4.1；带日期的 V4 Flash 和 V4.1 保持不同模型。已用原生 `provider set`
更新本机既有 `loongpass` 来源的目录、会话及失败策略，保留原统一 key，其他来源
配置逐项保持一致。独立临时配置探针还验证了两个单账号来源共存、单账号目录
更新和统一 key 替换，更新后来源数与 ID 不变。

### CI、发行与未覆盖项

macOS 代码 CI 已通过。Windows 初轮及一次重跑在 SDK 安装前下载 yq 时收到
HTTP504，应用测试尚未运行。CI 改为复用现有 Python 校验工具读取 pubspec 的
唯一版本值，避免额外安装 yq；仍校验实际安装的安全 SDK，不降低版本要求。
该变更使用新的失败回归、六项工具链检查、真实 SDK 验证和工作流语法检查验证。

修复后的 [代码 CI](https://github.com/SailingLoong/LoongPass/actions/runs/42472291101)
在提交 `20bf15e` 上通过 macOS 与 Windows 两项任务。Windows 首次到达编译阶段时
又遇到固定 C++ 依赖下载 HTTP504，重跑后构建、原生检查和打包通过，没有修改
依赖版本、校验或 TLS 设置。该提交仅修 CI 引导；随后验收文档修订不改变候选的
运行时源码。候选已从交付目录重启，恢复 27 项模型、六个来源和原调用权限。

本轮没有手动复算调用前后的官方余额，不据请求成功推导免费、零扣费或逐请求账单。
额度与计数修复的绝对值检查属于合成验证，官方领奖到账仍按各渠道单独验收。
真实运行机器为 Apple Silicon macOS；Universal 架构检查不代替 Intel 真机，
Windows 构建/模拟检查不代替 Windows 真实授权及调用。

其他模型、其他客户端、长上下文/长时间静默流、图片工具结果、结构化输出等没有
由本表推导为真实验收完成。没有创建新的公开 Release、更新签名 feed 或发布标签。

LoongPass 的一次推理只发送一次。Claude Code 2.1.311 的本地 HTTP400 试验仍
观察到 schema 恢复重发，即使普通重试和非流式 fallback 都已关闭，不能把客户端
开关描述成整个链路绝不重发。

未知领取保留原记录，不将本地午夜或循环的 server day_no 当作新的领取证明。
不能核实刷新轮换结果时保留阻断状态；没有有效续期授权时仍需要重新登录。
这些边界与恢复能力分别验证，不把重复发送当作修复。

LobsterAI 保持停用，ZCode 不回退付费套餐。未复制上游的身份改写、系统角色降级
或未知请求重发。WorkBuddy 可选 `free_only` 上游默认关闭；本轮不宣称新增筛选
功能，也不从模型名推断免费资格。TRAE 推理及其他未开放产品不是本轮已有能力。
