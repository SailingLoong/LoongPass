主线待发布

- Windows 安全维护：使用 Flutter 3.47.8 / Dart 3.13.7 重建，修复 GHSA-frr6-h895-5pxp；构建、打包与发布统一检查 SDK 版本。macOS 不受此项漏洞影响。
- 已准备独立的 1.0.1+32 安全候选，基于 v1.0.0 源码；真实 Windows 登录、授权恢复与签到回执仍需在该候选核对。正式包和更新源尚未替换。

- 移除 LobsterAI 的账号、奖励和辅助任务入口。官方限制第三方转接及额度共享，存在账号受限和永久停用风险。以下 1.0.0 内容保留原发布范围。

LoongPass 1.0.0：统一管理 AI 平台多账号、免费奖励和积分到期信息。

- 首次同时提供 macOS Universal、Windows x64 安装版和便携版。macOS 包包含 Apple Silicon 与 Intel 架构。
- WorkBuddy、MiniMax 国内版与海外版、Qoder 国内版与海外版、TRAE 国内版、ZCode 智谱 BigModel 独立管理账号、授权、奖励与余额。ZCode 按官方活动资格领取，保留固定设备绑定与未知领取记录。
- 紧凑账号工作区支持搜索、筛选、分页、常用账号、平台排序、浅深色和总览。
- 更新设置提供检查下载与 Beta 渠道两个独立选项，默认均关闭。关闭 Beta 时只接收正式版。原生更新器验证发布签名后安装，保留本机账号和设置。
- macOS 支持 WorkBuddy 官方客户端账号切换，以及选择单个 MiniMax 国内版账号和模型，经 Magpie 接入 Claude Code 的文本、流式与工具请求。Windows 当前提供账号、奖励和积分管理。
- macOS 新增 LobsterAI、Loomy 试验入口，真实授权与领取仍在验证。Loomy 按每日赠送池处理，避免重复补充已消耗额度。

安装与升级

macOS 下载 LoongPass-macOS-universal.zip，解压后将 LoongPass.app 放入应用程序目录。beta 29 及后续版本可通过应用内更新升级。Windows 日常使用选择 LoongPass-Windows-x64-Setup.exe，便携使用选择 LoongPass-Windows-x64.zip，完整解压后运行。两种 Windows 包共用当前用户的 AppData 账号目录。

应用目前使用 macOS 本地签名，尚未完成 Developer ID 公证；Windows 尚未配置 Authenticode 发布者签名。请从官网或本仓库 Release 下载并核对 SHA256SUMS。应用内更新另有 Ed25519 发布签名保护。

授权数据以明文保存在本机私有目录，采用权限保护、唯一写入者、原子写入与重复领取保护。辅助任务仅在应用运行期间按计划执行。活动开放、账号设备资格及最终余额以各平台官方结果为准；官方缺少的到期明细显示未知。

源码按 MIT 许可公开，保留第三方来源与声明。功能与设备验收范围见 https://github.com/SailingLoong/LoongPass/blob/main/VALIDATION.md 。
