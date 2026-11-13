LoongPass 1.0.1-beta.39

- 账号列表按「账号、即将到期积分、到期时间、最近领取时间、余额」排列，到期数量与时间分列，日期与时分分行显示。
- 常用桌面宽度直接显示全部五列；窄窗口和大字号自动改为账号下方排列字段，不再横向滚动表格。
- 余额只显示可核实的剩余数值与官方单位。原始额度摘要、使用率和上限移入详情；重叠额度不重复合计，未知值显示「—」。
- 最近领取时间只展示实际保存的领取时间，核验时间保留在详情。额度失败提醒、上次成功查询时间和原始明细继续保留。
- 侧栏拖动手柄悬停时显示张手、拖动时显示握手，去掉遮挡界面的排序浮层；键盘排序继续可用。
- 保留页面内自动检查、预下载与重启更新，以及完整上游插件、Flutter 3.50.0 / Dart 3.14.0、Bun 1.4.4 和 Forui 界面。

安装与升级

macOS 使用 LoongPass-macOS-universal.zip。Windows 日常使用 LoongPass-Windows-x64-Setup.exe，便携使用 LoongPass-Windows-x64.zip。应用内更新需开启「接收 Beta 版更新」。升级保留本机账号与领取记录。

ZCode 3.18 新版系统加密凭据暂不能从桌面客户端导入；请在添加账号时使用 BigModel 或 Z.ai 官方网页登录。已有可用授权保留。桌面切换的受限能力不会因本次同步而自动开放。

本版为 Beta。macOS 使用本地签名，Windows 尚未配置 Authenticode 发布者签名；原生更新器验证 Ed25519 发布签名。请从官网或本仓库 Release 下载并核对 SHA256SUMS 与 SOURCE_COMMIT。

本轮表格与余额口径见 docs/verification/2026-11-13-account-table.md；额度查询修复见 docs/verification/2026-11-13-account-facts.md，页面内更新见 docs/verification/2026-11-13-inline-updates.md。CI、模拟协议测试和真实账号验收分别记录。
