LoongPass 1.0.1-beta.33

- 模型接入重构为固定版本的 Magpie 原生插件宿主，完整复用 WorkBuddy、Qoder、MiniMax、TRAE、ZCode、Loomy 插件包。Magpie 负责客户端协议、模型分组、选路和推理恢复。
- 旧账号自动迁移，保留地区、账号身份、辅助任务设置、设备和领取历史。原始私有备份保留供迁移核对；未知领取不会因删除重加、个人/团队切换或设备换绑而重置。
- ZCode 普通模型赠送优先，再使用已有套餐；-Trial 明确为仅赠送。重新授权保留设备，换绑走原生认证，不购买套餐或充值。
- 修正 Qoder 将代码示例误判为工具调用、多个渠道额度精度与到期数据、Loomy 已用/剩余额度语义，以及桌面账号和授权恢复的身份隔离。
- 保留 WorkBuddy 官方客户端激活与独立的 Codex 账号管理。凭据应用与客户端身份验证分别报告。
- 使用 Flutter 3.47.8 / Dart 3.13.7。Windows 和 Intel 的真实账号覆盖与本机 Apple Silicon 验收分开记录。

安装与升级

macOS 使用 LoongPass-macOS-universal.zip。Windows 日常使用 LoongPass-Windows-x64-Setup.exe，便携使用 LoongPass-Windows-x64.zip。保留本机账号目录；首次启动会迁移旧授权存储。

本版为 Beta。应用内更新需开启「接收 Beta 版更新」。macOS 仍使用本地签名，Windows 尚未配置 Authenticode 发布者签名；原生更新器继续验证 Ed25519 发布签名。请从官网或本仓库 Release 下载并核对 SHA256SUMS 与 SOURCE_COMMIT。

实际模拟、构建与真实账号/客户端验收范围见 VALIDATION.md 及 docs/verification/2026-11-09-native-runtime.md。辅助任务仅在应用运行期间执行，奖励资格及最终余额以平台官方结果为准。
