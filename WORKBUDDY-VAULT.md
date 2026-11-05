# WorkBuddy 本地授权保存

当前版本将账号授权以明文 JSON 保存在应用私有目录 `Library/Application Support/LoongPass/WorkBuddy/accounts.json`。应用沙盒会将该相对目录放在自己的容器内。目录权限为 0700，文件权限为 0600。

存储后端使用 Foundation 的原子文件写入、文件与目录同步和现有进程所有权锁。JSON 中保留已验证的 UID、授权域名、接口域名、访问令牌、已知到期时间及记录版本。官网未返回到期时间时保留未知状态，恢复时向官网重新核验身份。

`WorkBuddyVaultStore` 是现有读写契约。原生后端提供读取、版本比较写入和保存记录列表。Dart 账号 owner 负责授权、身份验证及保存后的绑定，界面通过状态通知更新。

应用启动时恢复所有保存的账号并重新核验官网身份；失败时可使用现有“恢复已保存账号”按钮重试。自动签到行为见 [WORKBUDDY-AUTOMATIC.md](WORKBUDDY-AUTOMATIC.md)。授权文件与非凭据签到记录分开保存。

`tool/workbuddy_file_store_checks.swift` 使用临时目录和合成凭据验证明文文件、权限、比较写入、重新打开与凭据移除。真实账号授权、身份显示、重启恢复及签到以实际应用验收为准。
