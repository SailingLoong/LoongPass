# LoongPass

一个轻量、同机使用的 Flutter 账号工具，使用 Material 3，视觉参考 Semi 的紧凑桌面风格。一套 Flutter/Dart 代码，不另起 Go/Node 服务。

**当前是开发预览源码，不是已经接通真实账号的 1.0.0 beta 安装包。**

## 已有功能

- 单页账号列表、搜索、合成账号导入和切换。WorkBuddy、Qoder、MiniMax Code 的国内/国际账号暂为占位样例，ZCode 样例通过实际 Dart 切换核心操作。
- ZCode 七字段快照/切换决策：先保留当前最新 token，A→B→A 不回灌旧状态；只改变目标七键，保留其他内容；上下文不同、源状态变化则拒绝。
- 显式文件接口：严格读取 ZCode 字符串 JSON，拒绝重复键（包括转义别名）、异常 UTF-8/UTF-16、BOM、非字符串值及超过 4 MiB 的文件。
- 将完整原始字节备份至调用方提供的已有私有目录中的独立新子目录；核对写回字节和源状态。失败时不改原文件，并清理本次未完成备份。
- 从文件或备份重新导入七字段快照。保留已有密文字节，不引入新加密。

文件接口在 lib/zcode_auth_file.dart。macOS 界面已加入“选择文件并备份”和 Finder 查看入口，Cocoa 仅负责系统选择器、临时只读授权和私有目录；备份仍由 Dart 执行。取消不创建备份，完成或失败都会请求释放临时访问。

账号列表仍明确为合成样例，关闭不保存；真实切号、签到和自动签到按钮禁用，不显示假的成功结果。界面标记“开发预览”，不是完成的真实账号版本。

## 使用边界

这还不是安全改写客户端认证文件的原生适配器。未实现身份/本机上下文核验、原生密文解密、客户端进程和版本检查、系统钥匙串、原子替换与崩溃恢复、真实账号列表持久化、实际签到/领取和调度。导入快照不等于验证登录有效，不会让已撤销或过期的凭据重新有效。

备份接口不自动搜索真实认证文件、不覆盖原文件，不跨机器传送数据。当前仅允许 POSIX 平台，核私有根目录的模式位并拒绝路径别名；Windows ACL 未实现，备份主动拒绝。macOS 薄适配已加入目录所有权、严格0700、符号链接及空ACL检查，拒绝现有不合规目录且不修改其权限；这些原生检查仍待Mac编译和运行验证。本机账号身份验证仍未接通。无敌对同用户并发、原生文件锁、目录 fsync 或断电恢复保证。进程强制退出可能留下私有根目录内的未完成副本，但不会损坏原文件。

云端只用了合成临时文件。尚未在 Mac/Windows 真实客户端上测试；已生成 macOS runner，未生成 Windows runner、签名或安装包。当前活动的官方条件仍需由各平台适配按实际账号核实，不做设备身份伪造或资格限制绕过。

## 运行测试

需要官方 Flutter SDK。仅依赖 Flutter 与 Flutter Test SDK，没有第三方 UI 或运行时依赖。

```sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

也可运行 bash check.sh，支持 FLUTTER_ROOT 或 PATH 中的 Flutter。云端已有缓存自动离线，其他环境默认正常解析依赖；设置 PUB_OFFLINE=1 强制离线。

已验证：27 个文件测试、8 个平台桥接测试、14 个 Widget 测试、1 组含 29 项纯逻辑检查，共 50/50 Flutter 测试通过；format 与 analyze 通过。包括备份逐字节一致、异常不动源文件、源变化清理、符号链接加父目录跳转回归，以及 480/760/1280 宽度布局。

原生6个XCTest已写入 macos/RunnerTests/RunnerTests.swift，但云端无Swift/Xcode，未运行。系统文件选择、实际沙箱访问、Finder与原生安装包都需要Mac验收。桥接测试使用真实临时合成文件和模拟平台通道，不等于原生端到端测试。

## Mac 构建前置与验收

在另行授权的 Mac/Xcode 环境中，先运行上述 Dart 检查，再生成原生配置并跑 XCTest：

```sh
flutter build macos --debug --config-only --no-pub --build-name=1.0.0 --build-number=1
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS' test
flutter build macos --release --no-pub --build-name=1.0.0 --build-number=1
```

使用明确的数字 build-name，避免 Flutter 把 pubspec 中的 beta 字样转换成不合适的 macOS 版本号。beta 标记保留在源码版本和未来安装包名称中。签名、notarization 和分发尚未安排在本切片内；不要将未验收的开发预览发布为功能 beta。

Mac 人工验收先用自建无凭据 JSON：取消选择、重复点击、有效备份及Finder、错误JSON、源文件不变、异常后再次备份。真实认证文件必须另行按实际客户端验证，不能用此入口代表已经实现切号。

tool/render_preview_test.dart 是可选云端视觉取证工具，依赖该环境已有字体，不代表原生 Mac/Windows 实测。

## 来源

核心移植自 LoongPort 固定 commit 9e1b7e574e1ca923d8ee5aab3cd7ede16a8872b6 的 zcode_accounts/core.rs，沿用 MIT 许可并保留原版权。原 Rust 核心/密文 37 项和领取状态 19 项测试已分别通过；这不是整个旧后端或现行客户端的完整验证。详见 SOURCE-ORIGIN.md 和 LICENSE。
