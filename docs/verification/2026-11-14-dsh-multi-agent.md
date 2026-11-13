# 2026-11-14 DSH 多 agent 接入验收

本记录区分连接修复、自动检查、真实模型调用和发布安装。尚未完成的项目不会因为模型目录可见而判为通过。

## 连接修复

本机从桌面启动的 beta 38 原生宿主没有代理环境变量。在本机直连 DNS 失败、系统代理可用时，WorkBuddy 和 MiniMax 的基础请求均超时，Teams 尚未进入子 agent 阶段。

应用在创建 Bun 进程前，按 Magpie 原生约定读取系统手动 HTTP/HTTPS 代理并映射为 `MAGPIE_*_PROXY`，移除普通隐式代理变量。显式环境变量优先，保留本机绕过规则与 `NO_PROXY=*`。修复后的固定宿主在清除继承代理环境后，通过系统设置访问同一官方上游地址返回 HTTP 200；未使用账号凭据进行此网络探测。

## 自动检查

- 代理新增行为测试先失败，修复后通过；覆盖 macOS、Windows 配置、显式环境优先、IPv6、绕过规则及无效配置。
- 实际固定宿主的本地网络测试先复现 loopback 被误送到代理；修复后外部请求经过代理，本机请求直接送达。
- 305 项原生运行时测试、286 项 Flutter 测试、Dart 分析及所有 macOS 原生检查通过；固定来源及完整插件包校验通过。

## 真实 Agent Teams 接入

在 macOS Apple Silicon 上，使用官方安装版 DeepSeek Harness `0.2.2-rc.2`、Magpie `0.1.3346` 与 LoongPass `1.0.1-beta.41+41` 候选。候选代码为 `9cdbc96b9ed09154b444be13f84af8bc77e8a9b7`，从 beta 40 主线构建；正式安装包由 Release CI 独立生成，以 Release 的 `SOURCE_COMMIT` 和 `SHA256SUMS` 核对。

基础请求使用真实已授权账号，两种模型分别在 1.86 秒和 1.73 秒返回精确文本 `42`。随后在隔离 DSH profile 和临时工作目录中执行原生 Teams：

| 场景 | 真实结果 |
| --- | --- |
| 父会话创建任务并启动两个子 agent | 两个子会话同期开启，运行时间重叠 4.975 秒；先启动两者再等待 |
| WorkBuddy / `deepseek-v4.1-flash` 子 agent | 使用 Python 计算 `sum(range(1,101))`，写出 `sum.txt = 5050` |
| MiniMax / `MiniMax-M3.1-Flash` 子 agent | 使用 Python 计算 `6*7`，写出 `product.txt = 42` |
| 任务板与父会话汇总 | 两个任务由对应子 agent 领取并完成，均为 revision 3；父会话读取文件并调用 Python 得到 `5092`，全程 29.74 秒 |
| 停止 CLI 后恢复同一会话 | 新 CLI 进程读取原任务板、两个已结束的子 agent 和两个结果文件，4.98 秒完成；没有新建子 agent 或写文件 |

验收同时读取了父子会话工具事件、实际文件和持久任务状态，没有只依据模型的最终说明判定通过。两个子 agent 分别走 Magpie 的 OpenAI Completions 与 Anthropic Messages 提供方。一次向 `/dev/stderr` 写入的命令被 DSH workspace-write 沙箱拒绝，子 agent 随后在工作目录内完成写入，没有扩大权限或更换模型。

## 安装与数据保留

候选通过标准 macOS Universal 构建及签名完整性检查，替换 `/Applications` 中同一个 LoongPass 后以普通桌面入口启动。确认仅有一个应用进程，Bun 宿主收到原生 `MAGPIE_HTTPS_PROXY`，没有普通 `HTTPS_PROXY` 隐式代理变量。13 个账号身份、原生授权键和原有 65 条领取记录均完整保留。启动后的数据层自动领取继续运行，检查时共有 68 条领取记录。

macOS 与 Windows 的 PR CI 均已通过。本次没有界面改动；实际窗口视觉与交互不由本轮 headless 接入测试代替。

## Superagent 与覆盖边界

Superagent 的独立 profile、默认模型及 Eval / Execution 覆盖模型路径已按官方文档核对。在隔离 `DSH_HOME` 中，官方 DSH CLI 从 Web 模板生成独立 profile 并成功合成两种 Magpie 模型提供方配置；这只验证 profile 配置，不表示已经加载或验证 Superagent 原型。本次不部署 GitHub / 飞书 Sources，不执行外部消息、PR 或常驻恢复验收。该上游是研究原型，版本要求以其当前 manifest 为准。

Windows / Intel 真机多 agent 调用不在本轮已验证范围。系统代理变化需重启应用；PAC 和仅 SOCKS 的自动桥接未实现。
