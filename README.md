# LoongPass

统一管理多个 AI 平台的账号、免费签到奖励和积分到期信息。

macOS beta 提供 WorkBuddy、MiniMax CN、MiniMax、Qoder CN、Qoder、TRAE CN 和 ZCode 智谱 BigModel 的独立入口。国内外授权、账号与领取记录分别保存。自动检查仅在应用运行期间执行：启动约 30 秒后首次检查，ZCode 之后每 10 分钟检查活动，其他平台每 15 分钟检查。

当前源码新增 LobsterAI（有道）和 Loomy（讯飞）的独立账号入口：LobsterAI 使用官网浏览器授权，Loomy 使用本人手机号及短信验证码。两者支持多账号保存、自动检查、余额及领取记录；Loomy 领取的是当天赠送池，不会在使用后反复补充。此新增源码尚未随已发布 beta 30 安装包交付，真实账号登录及到账验收范围见 [VALIDATION.md](VALIDATION.md)。

## 下载和使用

从 [Releases](https://github.com/SailingLoong/LoongPass/releases) 下载 macOS Universal ZIP，解压后打开 LoongPass.app。支持 macOS 12 及以上，安装包同时包含 Apple Silicon 和 Intel 架构。

1. 在侧栏选择平台及地区，通过官方网页授权账号。
2. 授权完成后自动读取身份并保存。添加其他账号时重复授权操作。
3. 查看签到状态、当前余额、最近到期批次与该批次剩余额度。
4. 保持 LoongPass 运行以执行自动检查。重启后自动恢复保存的账号。

TRAE CN 可先选择官方客户端的 `User/globalStorage/storage.json`，读取当前登录和匹配设备身份，再通过官网授权独立账号。复用客户端的现有访问授权会显示到期边界。

WorkBuddy 提供客户端切换入口，两个真实账号已在 Apple Silicon 上完成往返切换和官方身份核对；其他平台的官方客户端切换尚未提供。验证范围见 [VALIDATION.md](VALIDATION.md)。

ZCode 按官方开放活动领取，使用账号固定的设备标识。新增账号优先分配未占用的已有设备号，不足时自动生成 UUIDv4；授权成功后随账号保存，后续重新授权继续复用。领取结果未知时保留原设备和领取记录，仅查询回执。需要先安装并打开一次官方 ZCode，以读取客户端版本和请求上下文；无需虚拟机。活动资格和最终发放以官方响应为准，详见 [ZCODE-ACTIVITIES.md](ZCODE-ACTIVITIES.md)。

当前包使用本地签名。系统可能提示开发者身份未验证，需要按 macOS 的“隐私与安全性”提示确认打开。当前真实验收范围及待验证项见 [VALIDATION.md](VALIDATION.md)。

## 应用更新

设置提供「自动检查并下载更新」和「接收 Beta 版更新」两个独立开关，均默认关闭。Beta 关闭时只接收正式版，开启时也接收测试版；手动检查使用同一渠道规则，不会降级当前版本。macOS 原生 Sparkle 负责偏好、调度、签名校验和安装，打开设置页只读取状态。开启自动更新后，验证完成的更新可在退出时安装，也可主动安装并重启，保留账号数据和设置。beta 29 可应用内升级；更早版本首次需手动安装。已有安装若未同时允许自动检查和下载，合并后的自动选项保持关闭。

## 本机数据

授权以明文保存在应用私有目录，目录权限 0700，文件权限 0600。beta 21 使用沙箱容器；beta 22 普通桌面版使用 `~/Library/Application Support/LoongPass`，首次升级整体迁移旧账号库，升级后请使用新版本。普通桌面版可按当前用户权限访问文件和进程，用于核对并切换官方客户端。保存采用唯一写入者、原子替换及版本比较。授权令牌只发送给对应平台的官方接口。请勿将账号文件提交到 Git 或作为问题附件上传。

积分页优先展示官方返回的当前剩余额度。套餐续期时间、奖励发放额度和积分包当前余额分别处理。接口缺少明细时会显示范围与缺口。

## 账号表格

账号页按「账号、余额、即将到期、最近领取」展示，默认每页 10 个，可切换为 5 或 20 个。
搜索、常用筛选和到期排序作用于整个平台的账号；切换页面不会切换客户端。
点击账号查看签到、自动领取设置和完整明细。支持客户端切换的平台在账号旁提供切换按钮，
鼠标悬停或键盘聚焦时显示；窄窗口可横向滚动表格，浅深色跟随系统。

最近领取只展示已确认记录，后续领取未确认时保留上次成功。旧记录没有具体时刻时显示时间未知；
TRAE 的余额净增与发放金额分开标明，Qoder 套餐与附加额度分别显示。到期列展示最近一批的
当前剩余量，点击可看最近三批及查询时间。表格不会因搜索或查看明细而触发签到。

工作区包含总览、全部账号、活动记录和设置。侧栏可折叠、调整平台顺序并在重启后恢复；地区标签帮助区分国内外入口。Magpie 页面目前仅说明后续接入方向，尚不能向其他软件提供模型调用或积分路由。

## 从源码构建

使用 Flutter 3.47.1、Xcode 和 `rust-toolchain.toml` 锁定的 Rust 工具链。

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
flutter pub get
python3 tool/check.py
python3 tool/build_macos_release.py
```

构建脚本持有本机打包锁，复用 `~/Library/Caches/LoongPass/native-macos`。产物位于 `build/macos/Build/Products/Release/LoongPass.app`。编译库、账号文件、构建缓存和安装包由 Git 忽略。

推送与 `pubspec.yaml` 版本一致的 `v1.0.0-beta.N` tag 会触发 CI 构建 Universal 包、校验架构与签名，并创建 GitHub prerelease。

## 贡献与许可

项目方向和工程约束见 [AGENTS.md](AGENTS.md)，协议来源见 [SOURCE-ORIGIN.md](SOURCE-ORIGIN.md)。MIT 许可及第三方声明随源码保留。
