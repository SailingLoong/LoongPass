# LoongPass 最小接口接线候选

## macOS 源码构建

使用 Xcode、Flutter 和项目锁定的 Rust 1.95.0。先安装两种 macOS Rust 标准库，再通过 Flutter 的正常构建入口编译。

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
flutter pub get
flutter build macos --release
```

Xcode 构建阶段调用 `tool/build_macos_native.sh`，按目标架构从 `native/switch` 及其锁定依赖生成静态库。Cargo 缓存默认位于 `~/Library/Caches/LoongPass/native-macos`，可通过 `CARGO_TARGET_DIR` 指定已有兼容缓存。生成的静态库、构建输出与缓存不纳入 Git。

保留 ZCode、Qoder、MiniMax、WorkBuddy 四 App 侧栏，不添加样例账号、假成功按钮或通用备份界面。

## 当前工作范围

本次只开放 WorkBuddy 多账号正常入口：官方授权、身份显示、本机明文保存、启动恢复及应用运行期间自动签到。其他平台源码保留。本机授权文件和编译产物不纳入 Git，不增加钥匙串或加密存储。

当前实现、已执行检查及真实验收边界见 [SINGLE-ACCOUNT-STATUS.md](SINGLE-ACCOUNT-STATUS.md)。存储与自动化规则分别以 [WORKBUDDY-VAULT.md](WORKBUDDY-VAULT.md)、[WORKBUDDY-AUTOMATIC.md](WORKBUDDY-AUTOMATIC.md) 为准。

源码来源与 beta 18 交接依据保留在 [SOURCE-ORIGIN.md](SOURCE-ORIGIN.md) 和 [TRANSFER-NOTES.md](TRANSFER-NOTES.md)。Git 当前树仅保留源码、必要配置、源资源及文档；旧历史提交包含过编译库，未改写历史。
