LoongPass 1.0.3-beta.60

- 重启后，本机已保存的账号会先显示。模型与额度在后台刷新，较快来源的余额会先更新。同一来源的账号仍依次查询。
- 来源暂时离线时，可以查看已保存的账号并重试刷新。首次刷新完成后，LoongPass 才向 Magpie 同步模型、启用 Auto 并显示「无可用模型」标识。

安装与升级

macOS 使用 LoongPass-macOS-universal.zip。Windows 提供安装版和便携 ZIP。已安装用户可在设置中开启「接收 Beta 版更新」，然后选择「检查更新」。

macOS 使用本地签名，Windows 更新器通过 Ed25519 验证安装包。安装包 SHA-256 和构建对应的源码提交见本页的 SHA256SUMS 与 SOURCE_COMMIT。
