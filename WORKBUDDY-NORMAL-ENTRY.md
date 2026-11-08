# WorkBuddy 正常入口

使用 `lib/main.dart` → `AccountToolApp` → 现有 `WorkBuddyAccountsPanel(savedAccounts: true)`。启动时打开 WorkBuddy 页面，侧栏提供各平台及地区的独立入口。本次不增加调试入口。

页面提供官方授权、身份显示、已保存账号恢复、状态/额度查询及签到。启动恢复由页面初始化接入账号 owner，授权结果轮询和辅助签到定时器由各自控制器负责。账号保存及辅助任务契约分别见 [WORKBUDDY-VAULT.md](WORKBUDDY-VAULT.md) 和 [WORKBUDDY-AUTOMATIC.md](WORKBUDDY-AUTOMATIC.md)。

包标识保持 `com.sailingloong.loongpass.workbuddy.identityrelease`，以复用已有应用容器。源码中的功能开关不代表实号验收结论；当前构建与实号证据统一记录在 [SINGLE-ACCOUNT-STATUS.md](SINGLE-ACCOUNT-STATUS.md)。
