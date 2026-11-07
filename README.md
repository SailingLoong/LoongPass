<div align="center">

# LoongPass

### 把 AI 账号、免费奖励与积分到期放在一起

[![下载最新版](https://img.shields.io/github/v/release/SailingLoong/LoongPass?label=下载最新版&color=2ea44f&style=for-the-badge)](https://github.com/SailingLoong/LoongPass/releases/latest)

[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey.svg)](https://github.com/SailingLoong/LoongPass/releases)
[![Flutter](https://img.shields.io/badge/built%20with-Flutter-02569b.svg)](https://flutter.dev)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)


[官方网站与下载](https://loongpass.com) · [更新记录](https://github.com/SailingLoong/LoongPass/releases) · [问题反馈](https://github.com/SailingLoong/LoongPass/issues)

</div>

## 它替你做什么

多个 AI 平台、国内与海外版本、不同账号的余额和到期时间，集中放进同一个桌面工作区。

- **多账号授权与恢复**。通过平台官方页面登录，核对账号身份后保存，重启继续使用。
- **免费奖励自动领取**。检查平台实际开放的签到或活动，记录发送状态和官方回执，保留未知结果以防重复提交。
- **余额与到期查看**。按平台官方单位展示余额、最近到期批次及剩余额度，同时保留查询时间。
- **紧凑账号工作区**。支持搜索、筛选、分页、常用账号和平台排序，并提供跨平台总览及活动记录。
- **签名应用更新**。独立设置自动检查下载与 Beta 更新渠道，按所选渠道获取后续版本。

<img src="docs/images/workspace.png" alt="LoongPass 账号工作区，使用虚构账号与演示数据" width="1024">

界面示意由实际 Flutter 组件渲染，账号与数值均为虚构数据。

## 三分钟上手

1. 从官网或 GitHub Release 下载对应系统的安装包。
2. 在侧栏选择平台及地区，点击授权并在官方页面完成登录。
3. 核对身份并保存账号，再查看余额、到期信息与已确认领取记录。
4. 按账号开启自动任务，保持 LoongPass 运行。重启后会恢复已保存账号。

国内版与海外版使用各自的官方授权入口，账号、凭据和领取记录分别保存。奖励开放时间、账号及设备资格、最终发放均以平台官方响应为准。

## 安装

| 系统 | 安装包 | 使用方式 |
| --- | --- | --- |
| macOS 12 及以上 | [Universal ZIP](https://github.com/SailingLoong/LoongPass/releases/latest/download/LoongPass-macOS-universal.zip) | 包含 Apple Silicon 和 Intel 架构，解压后将 LoongPass.app 放入应用程序目录 |
| Windows 10 / 11 x64 | [安装版](https://github.com/SailingLoong/LoongPass/releases/latest/download/LoongPass-Windows-x64-Setup.exe) | 按当前用户安装 |
| Windows x64 | [便携 ZIP](https://github.com/SailingLoong/LoongPass/releases/latest/download/LoongPass-Windows-x64.zip) | 完整解压后运行 LoongPass.exe，保留同目录 DLL 和 data 文件夹 |

每个 Release 附带 `SHA256SUMS` 与 `SOURCE_COMMIT`，用于核对安装包和源码版本。Windows 安装版与便携包共用用户数据目录，应用内更新使用安装程序。

当前 macOS 包使用本地签名，尚未进行 Developer ID 公证。Windows 包尚未配置 Authenticode 发布者签名。应用更新包另有发布密钥签名，由原生更新器验证。实际设备与功能验收范围记录在 [VALIDATION.md](VALIDATION.md)。

## 支持的平台

| 平台 | 授权与账号 | 奖励及积分 |
| --- | --- | --- |
| WorkBuddy | 官方授权、多账号保存，macOS 支持官方客户端账号切换 | 签到、余额及领取记录 |
| MiniMax CN / MiniMax | 国内与海外入口独立 | 签到、余额、奖励批次与到期信息 |
| Qoder CN / Qoder | 国内与海外入口独立，保存设备绑定 | 活动核对、套餐和附加积分、领取记录 |
| TRAE CN | 官方设备身份导入与官网授权 | 余额、领取及到期信息 |
| ZCode 智谱 BigModel | 官方授权、多账号和固定设备绑定 | 官方活动发现、领取、余额与到期批次 |
| LobsterAI / Loomy（macOS） | 官网授权或本人手机号短信验证，多账号保存 | 每日奖励、余额和领取记录，Loomy 不反复补充已消耗赠送池 |

ZCode 需要先安装并打开一次官方客户端，以读取版本、已有设备信息和请求上下文。添加账号时优先分配未占用的已有设备号，不足时生成 UUIDv4，授权成功后固定保存。领取结果未知时继续核对原设备与回执。详情见 [ZCODE-ACTIVITIES.md](ZCODE-ACTIVITIES.md)。

TRAE CN 需要官方客户端设备信息，可选择其 `User/globalStorage/storage.json` 导入。复用官方客户端访问授权时，界面会显示授权归属与到期边界。

自动任务在 LoongPass 运行期间执行。启动约 30 秒后首次检查，ZCode 随后每 10 分钟检查活动，其他平台每 15 分钟检查。各平台的实际能力及待验证项以验收记录为准。

## 应用更新

设置提供两个独立开关。

- **自动检查并下载更新**。默认关闭。macOS 验证后可在退出时安装，也可主动安装并重启。Windows 验证后打开安装程序。
- **接收 Beta 版更新**。默认关闭。关闭时只接收正式版，开启时也接收测试版。手动检查遵循同一渠道选择。

更新按构建号比较版本，并保留本机账号与设置。beta 29 及后续 macOS 版本可通过应用内更新升级。

## 数据与隐私

授权以明文保存在本机应用私有目录。macOS 使用 `~/Library/Application Support/LoongPass`，目录权限 0700、文件权限 0600。Windows 使用 `%APPDATA%\LoongPass`，通过当前用户与 SYSTEM 的私有访问控制保护文件。

保存采用唯一写入者、版本比较、原子替换和读回核对。账号授权发送至对应平台的官方接口。请保管账号目录，提交问题时移除令牌、设备标识及原始认证响应。

积分按官方单位展示。到期明细缺失时显示未知，已发放额度与当前剩余额度分别处理。

最近领取只展示已确认记录，后续领取未确认时保留上次成功。旧记录没有具体时刻时显示时间未知；
TRAE 的余额净增与发放金额分开标明，Qoder 套餐与附加额度分别显示。到期列展示最近一批的
当前剩余量，点击可看最近三批及查询时间。表格不会因搜索或查看明细而触发签到。

工作区包含总览、全部账号、模型服务、活动记录和设置。侧栏可折叠、调整平台顺序并在重启后恢复；地区标签帮助区分国内外入口。

## Magpie 模型服务（macOS）

macOS 可将已保存的 MiniMax 账号作为本机 Magpie 的模型来源。

1. 在「模型服务」中选择来源、已保存账号和官方客户端配置中的模型 ID，点击「保存并启动」。
2. 点击「复制 Magpie 接入链接」，在 Magpie 中导入。
3. 在 Magpie 中为客户端选择 LoongPass 的模型，保持 LoongPass 运行。

服务监听 `127.0.0.1:3426`，使用独立的本地调用密钥。平台令牌由原账号模块管理并发送给官方接口，Magpie 配置保存的是本地连接密钥。连接的账号、模型及启用意图跨重启恢复；停止操作在停用设置保存后关闭服务，保存失败可重试。

已通过 Claude Code 实测 MiniMax CN 的 `MiniMax-M3.1-Flash` 文本、流式及工具往返。本次连接固定使用一个账号和模型，国际版真实调用、其他平台推理与多账号调度分别推进。源码运行验收及积分核对范围见 [Magpie 连接验收](docs/verification/2026-11-07-magpie-connection.md)。

## 从源码构建

使用 Flutter 3.47.1 和锁定依赖。macOS 还需 Xcode 与仓库指定的 Rust 工具链，Windows 还需 Visual Studio 的 C++ 桌面开发工具、CMake 与 Python。

```bash
flutter pub get --enforce-lockfile
python3 tool/check.py
python3 tool/build_macos_release.py
```

Windows 构建与打包可在 PowerShell 执行。

```powershell
flutter pub get --enforce-lockfile
flutter build windows --release
.\tool\package_windows.ps1
```

安装程序打包使用 Inno Setup 6。正式发布由 GitHub Actions 构建两个平台，检查通过后生成签名更新清单并发布 Release。

## 开源与致谢

LoongPass 以 MIT 许可公开。账号与活动适配参考 LoongPort、workbuddy-switch 和 zcode-switch，并保留原作者声明。第三方组件的来源和许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
