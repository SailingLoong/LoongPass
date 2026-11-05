# LoongPass

统一管理多个 AI 平台的账号、免费签到奖励和积分到期信息。

macOS beta 提供 WorkBuddy、MiniMax CN、MiniMax、Qoder CN、Qoder 和 TRAE CN 的独立入口。国内外授权、账号与领取记录分别保存。当前自动检查在应用运行期间执行，启动约 30 秒后首次检查，之后每 15 分钟检查。

## 下载和使用

从 [Releases](https://github.com/SailingLoong/LoongPass/releases) 下载 macOS Universal ZIP，解压后打开 LoongPass.app。支持 macOS 12 及以上，安装包同时包含 Apple Silicon 和 Intel 架构。

1. 在侧栏选择平台及地区，通过官方网页授权账号。
2. 授权完成后自动读取身份并保存。添加其他账号时重复授权操作。
3. 查看签到状态、当前余额、最近到期批次与该批次剩余额度。
4. 保持 LoongPass 运行以执行自动检查。重启后自动恢复保存的账号。

TRAE CN 可先选择官方客户端的 `User/globalStorage/storage.json`，读取当前登录和匹配设备身份，再通过官网授权独立账号。复用客户端的现有访问授权会显示到期边界。实际客户端切换仍待完成。

当前包使用本地签名。系统可能提示开发者身份未验证，需要按 macOS 的“隐私与安全性”提示确认打开。当前真实验收范围及待验证项见 [VALIDATION.md](VALIDATION.md)。

## 本机数据

授权以明文保存在应用沙盒的私有目录，目录权限 0700，文件权限 0600。保存采用唯一写入者、原子替换及版本比较。授权令牌只发送给对应平台的官方接口。请勿将账号文件提交到 Git 或作为问题附件上传。

积分页优先展示官方返回的当前剩余额度。套餐续期时间、奖励发放额度和积分包当前余额分别处理。接口缺少明细时会显示范围与缺口。

## 从源码构建

使用 Flutter 3.47.1、Xcode 和 `rust-toolchain.toml` 锁定的 Rust 工具链。

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
flutter pub get
python3 tool/check.py
python3 tool/build_macos_release.py
```

构建脚本持有本机打包锁，复用 `~/Library/Caches/LoongPass/native-macos`。产物位于 `build/macos/Build/Products/Release/LoongPass.app`。编译库、账号文件、构建缓存和安装包由 Git 忽略。

推送与 `pubspec.yaml` 版本一致的 `v1.0.0-beta.N` tag 会触发 CI 构建 Universal 包、校验架构与签名，并创建 GitHub prerelease。

## 贡献与许可

项目方向和工程约束见 [AGENTS.md](AGENTS.md)，协议来源见 [SOURCE-ORIGIN.md](SOURCE-ORIGIN.md)。MIT 许可及第三方声明随源码保留。
