# WorkBuddy 保存与恢复流程

正常入口使用同一条 AuthState → 官方网页 → AuthToken → Profile → 保存 → 绑定 → 账号列表流程。`WorkBuddyAccounts.pollAndSave` 只有在身份和保存绑定完成后才发布账号就绪事件；页面不把待授权会话当成账号。

`restoreSaved` 按保存记录逐一恢复账号；某个账号失败不影响其余账号，复用 Profile 接口核验 UID、域名及授权。已知到期时间失效、身份不匹配或记录处于撤销/轮换状态时，不开放签到。已显示账号的授权失效后保留身份和重新授权提示，不让账号静默消失。没有到期字段的授权也必须重新核验身份，不能凭本地 UID 恢复。

存储与进程锁的权威契约见 [WORKBUDDY-VAULT.md](WORKBUDDY-VAULT.md)，恢复后的调度见 [WORKBUDDY-AUTOMATIC.md](WORKBUDDY-AUTOMATIC.md)，实际验收见 [SINGLE-ACCOUNT-STATUS.md](SINGLE-ACCOUNT-STATUS.md)。本地结束会话保留授权文件和签到日志，不代表官网撤权。
