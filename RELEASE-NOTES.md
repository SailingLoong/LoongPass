LoongPass 1.0.3-beta.59

- Magpie 和 LoongPass Auto 共用一份模型列表。在「模型连接」勾选要显示的模型即可。升级会沿用已有展示选择，新发现的模型默认关闭。
- 默认的「模型优先」按 Magpie「路由」中的顺序调用，每个模型只列一次。LoongPass 运行且已连接时，每分钟同步顺序。「积分到期优先」也只使用这批模型，到期时刻相同再按 Magpie 顺序选择。
- 账号没有任何可用模型时，「账号与积分」和「连接设置」会在账号旁标出「无可用模型」。有模型恢复可用时，标识会消失。

安装与升级

macOS 使用 LoongPass-macOS-universal.zip。Windows 提供安装版和便携 ZIP。已安装用户可在设置中开启「接收 Beta 版更新」，然后选择「检查更新」。

macOS 使用本地签名，Windows 更新器通过 Ed25519 验证安装包。安装包 SHA-256 和构建对应的源码提交见本页的 SHA256SUMS 与 SOURCE_COMMIT。
