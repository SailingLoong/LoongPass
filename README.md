# LoongPass 最小接口接线候选

保留 ZCode、Qoder、MiniMax、WorkBuddy 四 App 侧栏，不添加样例账号、假成功按钮或通用备份界面。

## 已写入代码的流程

- Qoder 中国区：主动确认持久授权 → 官方浏览器 → 手动检查结果 → 保存账号 → 指定账号核对并签到。取消区分 cancelled/completed/unknown，不把不确定保存说成取消成功。
- Qoder 国际版：原有配置文件导入保留，仍未接通认证与签到。
- MiniMax：中国区/国际区 → 用户选择真实凭据文件 → 明确令牌传输验证 → 显示服务端 UID → 再次确认保存到 LoongPass 钥匙串 → 主动签到或选择开启应用运行期间自动签到。未知请求不重复发送。
- ZCode、WorkBuddy：明确显示真实切换/签到尚未接通。

这些是已接线的候选源码，不是已完成实机验收的功能。所有官方桌面凭证切换仍未实现。Qoder CN 没有自动签到/自动刷新；MiniMax 只有应用内定时检查，不是系统后台服务。

页面导航不读取账号、不请求网络。MiniMax 只有主动加载已保存账号或明确启用后才运行已保存的自动设置。凭据不显示、不写日志，只使用本应用自己的钥匙串。没有增加数据库框架或新依赖。

当前 nativeAccountAdaptersValidated=false。两条新真实账号操作入口均禁用，只有完成 Mac 编译、隔离原生钥匙串验证及审查后才能开放。

## 验证与权限

仅执行 Python 静态文件摘要、相对 import、Runner 源文件引用及 plist 差异检查。Debug/Profile 与 Release 仅新增出站网络 client entitlement，保留既有文件选择只读权限。

未运行 Flutter/widget、analyzer、formatter、Swift/Xcode、真实 Keychain 或任何真实账号接口。两份新面板 widget 测试为未执行草稿，历史基线测试数量不代表当前版本。不要重试先前明确拒绝的测试。完整边界见 VALIDATION.md。

本目录是独立副本，原精简候选和各模块 writer 源码未改。回滚直接弃用此副本。模块来源与文件摘要见上级 evidence 与 SHA256-MANIFEST.json；MIT 许可保留。
