LoongPass 1.0.3-beta.53

- 「总览」和「辅助签到」页新增「辅助签到（N）」入口。点击一次后逐个核对已授权且支持辅助签到的账号，并协助领取当前开放的奖励。
- 启动、定时检查和账号变更时只读取奖励状态。手动领取继续使用官方回执核对结果，并防止重复领取。
- 延续 Beta 52 的模型命名修复。LoongPass 与 Magpie 使用厂商官网 API ID，实际请求使用对应账号的 App 原始模型 ID。

安装与升级

macOS 使用 LoongPass-macOS-universal.zip。Windows 提供安装版和便携 ZIP。已安装用户可在设置中开启「接收 Beta 版更新」，然后选择「检查更新」。

macOS 使用本地签名，Windows 更新器通过 Ed25519 验证安装包。安装包 SHA-256 和构建对应的源码提交见本页的 SHA256SUMS 与 SOURCE_COMMIT。
