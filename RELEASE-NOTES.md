LoongPass 1.0.1-beta.38

- 修复共用账号列表漏掉插件返回的纯文本余额和仅有官方摘要的额度窗口。
- 额度查询失败时保留本次运行中上次成功的数值与查询时间，明确标为上次结果；失效授权与查询失败进入待处理，不再显示成一次正常查询。
- 模型加载失败时继续独立读取官方额度，账号身份核验与领取保护保持生效。
- 领取记录显示已保存的核验时间，并与官方领取时间区分；历史记录未提供的金额、领取时间及积分到期日仍明确保留未知。
- ZCode 详情区分当前活动额度与历史领取记录；有 Coding Plan 套餐但旧授权缺少套餐权限时，请通过官方重新授权后核对。
- 保留 Beta 37 的页面内自动检查、预下载与重启更新，以及完整上游插件、Flutter 3.50.0 / Dart 3.14.0、Bun 1.4.4 和 Forui 界面。

安装与升级

macOS 使用 LoongPass-macOS-universal.zip。Windows 日常使用 LoongPass-Windows-x64-Setup.exe，便携使用 LoongPass-Windows-x64.zip。应用内更新需开启「接收 Beta 版更新」。升级保留本机账号与领取记录。

ZCode 3.18 新版系统加密凭据暂不能从桌面客户端导入；请在添加账号时使用 BigModel 或 Z.ai 官方网页登录。已有可用授权保留。桌面切换的受限能力不会因本次同步而自动开放。

本版为 Beta。macOS 使用本地签名，Windows 尚未配置 Authenticode 发布者签名；原生更新器验证 Ed25519 发布签名。请从官网或本仓库 Release 下载并核对 SHA256SUMS 与 SOURCE_COMMIT。

本轮账号额度修复范围见 docs/verification/2026-11-13-account-facts.md；页面内更新见 docs/verification/2026-11-13-inline-updates.md，上游同步见 docs/verification/2026-11-12-upstream-sync.md。CI、模拟协议测试和真实账号验收分别记录。
