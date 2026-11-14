# 在飞书使用本机 DSH Teams

飞书负责发任务、接收结果和处理审批。这台电脑运行 DeepSeek Harness，原生 Agent Teams 调用本机工具。Magpie 将模型请求转到 LoongPass 已授权的账号。

```text
飞书私聊 / 群聊
      ↓ 长连接
dsh-lark-channel → 本机 DSH 会话与 Agent Teams
                               ↓
                         Magpie → LoongPass
```

接入采用社区 `dsh-lark-channel@0.0.7`，固定来源和必要兼容补丁随本仓保存。原生 DSH 管理模型、工具、子 agent、任务板与会话记录，插件管理飞书消息和卡片。源码交付使用 GitHub，飞书任务在本机执行。[插件来源](https://github.com/omdsh-dev/dsh-lark/tree/632807d9abafbb866a5e208a0298eff21c7856d1)

## 准备独立 profile

安装 DeepSeek Harness，确认 LoongPass 本机服务和 Magpie 网关可用。在本仓执行以下命令，安装器会通过 DSH 原生插件管理器安装固定版本，并用 pnpm 的补丁机制应用兼容修正。

```sh
python3 tool/install_dsh_feishu.py --profile loongpass-feishu
```

默认使用 PATH 中的 `dsh`，macOS 也会识别官方桌面包自带的 CLI。其他位置通过 `--dsh` 指定。配置、会话和已安装依赖保存在 `DSH_HOME` 下，默认是 `~/.dsh`。

准备一个实际工作目录，再写入此 profile 的 Teams 和飞书配置。下例的模型 ID 应从当前 Magpie 目录选择。

```sh
mkdir -p "$HOME/LoongPassTasks"
python3 tool/configure_dsh_feishu.py \
  --profile loongpass-feishu \
  --workspace "$HOME/LoongPassTasks" \
  --model magpie/loongpass/workbuddy/deepseek-v4.1-flash
```

配置工具复用 LoongPass 已准备的 Bun 运行时。首次使用前启动 LoongPass 完成运行时初始化，也可用 `LOONGPASS_BUN` 指定已准备的 Bun。

工具维护专属配置块，接受 DSH 原生写出的 YAML，保留凭据引用、聊天状态和 Magpie 配置。遇到已有的 Teams 或飞书自定义行会报告冲突并保留原文件。写入与 DSH 配置编辑器共用原生文件锁。`workspaceRoots` 默认限定到所选工作目录，实际工具读写权限由 DSH 的权限预设和沙箱决定。

在 Magpie 中确认新 profile 已包含模型来源。Magpie 原生同步负责维护该来源。首次消息前先验证普通模型请求与终端工具。[Magpie DSH 接入实现](https://github.com/yetone/magpie/blob/main/internal/agent/dsh.go)

## 绑定飞书

从已安装的 profile 启动原生频道管理命令。macOS 桌面安装可将其 CLI 目录加入当前命令环境的 PATH。

```sh
export PATH="/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin:$PATH"
node "${DSH_HOME:-$HOME/.dsh}/profiles/loongpass-feishu/node_modules/dsh-lark-channel/lib/cli.js" \
  start --profile loongpass-feishu --workspace "$HOME/LoongPassTasks"
```

首次启动显示飞书官方绑定页面和二维码。扫码页面可以创建专用机器人或重新授权已有应用。扫码人需要完成飞书侧的确认，凭据由 DSH 原生 credentials/settings 服务保存。已有应用可在配置工具中传 `--app-id`。

扫码完成后，核对注册者在该应用下的 `open_id`。注册回执可能直接返回该身份；回执缺少时，先由本人私聊机器人，再用此应用的机器人身份读取该聊天消息的发送者 `open_id`。用已核实的身份收窄私聊和审批范围，再重启服务。

```sh
python3 tool/configure_dsh_feishu.py \
  --profile loongpass-feishu \
  --workspace "$HOME/LoongPassTasks" \
  --model magpie/loongpass/workbuddy/deepseek-v4.1-flash \
  --sender-allowlist ou_REPLACE_WITH_REGISTERED_USER \
  --approvers ou_REPLACE_WITH_REGISTERED_USER
node "${DSH_HOME:-$HOME/.dsh}/profiles/loongpass-feishu/node_modules/dsh-lark-channel/lib/cli.js" restart
```

飞书应用可用范围决定谁能找到机器人。`senderAllowlist` 约束私聊，`groupAllowlist` 约束允许的群，`approvers` 约束审批人。空名单沿用上游开放语义。群内成员共同使用机器人，默认通过 @ 触发。需要群聊时，通过配置工具的 `--group-allowlist` 填入目标 `chat_id`，并将机器人加入对应群。

## 使用与验证

- 私聊机器人发送 `/status`，核对工作目录、模型和会话。
- 发一项简单任务，再要求父 agent 启动两个子 agent 并使用原生任务板。新根会话默认启用 Teams。
- DSH 原生策略实际发起的工具审批会回传卡片。子 agent 的审批保留该子 agent 的请求身份与实际命令。默认委派策略为 `never` 时，子 agent 的越权请求按原生规则拒绝，父 agent 可在自己的权限范围内处理后续工作。
- `/stop` 停止当前任务，后续消息继续会话。`/new` 开新会话，`/model` 选择模型，`/ws` 和 `/cd` 管理允许的工作目录。
- 重启频道后，再发一条消息核对历史上下文。飞书聊天、话题和工作目录的会话归属由上游插件保存。

后台服务由上游 CLI 使用 macOS launchd 或 Linux systemd 管理。`status`、`logs`、`restart`、`stop` 命令均通过上述 `lib/cli.js` 执行。需要代理的环境在首次 `start` 时提供标准代理环境变量，兼容补丁将它们传给后台服务。电脑休眠或关机期间，执行与长连接会中断。

## 验证范围

本次兼容修正覆盖工具展示作用域、子 agent 审批归属、停止原因格式、后台代理继承，以及新版 DSH 原生设置与凭据保存。凭据通过原生存储持有，profile 保存引用和聊天状态。安装前后校验上游文件，升级通过更新固定来源和复测完成。各版本的实际覆盖见验证记录。

上游的消息去重缓存保存在进程内。重启后可能收到重复事件，长连接中断期间的消息也没有补拉保证。涉及外部写入的任务需要核对实际结果后再重发。会话历史恢复与消息投递保证分别验收。[验证记录](verification/2026-11-14-dsh-feishu.md)
