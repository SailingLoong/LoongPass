# WorkBuddy 界面与账号隔离

正常入口使用 `WorkBuddyAccountsPanel(savedAccounts: true)`，由 `WorkBuddyAccounts` 管理多个独立账号。授权、恢复及辅助签到契约分别维护在 `WORKBUDDY-AUTH593.md`、`WORKBUDDY-RESTORE.md` 和 `WORKBUDDY-AUTOMATIC.md`。真实验收见 `VALIDATION.md`。

每次授权保留独立的状态、有效期、凭据代次和请求准入。只有 Profile 核实的域名与 UID 进入账号列表。页面选中状态只决定当前展示对象，请求及迟到结果始终绑定原账号。所有签到进入 `WorkBuddyClaimCore`，由持久化日志判重并核对官方回执与余额增量。

页面分别展示官方签到状态、完整余额、积分包到期明细和本次到账结果。余额读取要求官方返回完整集合，分页缺失或数据冲突时保留未知状态。相同资源 ID 去重，已到期资源排除，缺少到期时间的余额单独展示。查询时间随快照显示。

移除本次内存账号会结束该会话的定时检查，保存的授权和领取记录仍可供下次启动恢复。账号保存、应用内视图选择和官方客户端实际切换分别验收。
