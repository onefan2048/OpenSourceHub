# OpenSource Hub — iOS 独立版 (`.ipa`)

面向 iPhone 竖屏优化的原生独立版 OpenSource Hub，参考 LCSign 的交互与视觉风格，不依赖 Docker 或外置服务器，打开即可随时下拉刷新、实时同步 GitHub 开源软件源。

## 体积优化（从 Docker 600 MB → iOS `.ipa` 约 1–2 MB）

- **零外部第三方依赖**：完全基于 iOS 系统内置框架（`SwiftUI`、`SQLite3`、`CryptoKit`、`URLSession`、`BackgroundTasks`、`UserNotifications`），不打包 Node.js、Prisma 或 Web 运行时。
- **编译与打包瘦身**：`project.yml` 开启 `arm64` 单架构、`-Osize`、`LLVM_LTO=YES_THIN`、`DEAD_CODE_STRIPPING=YES`、`STRIP_STYLE=all`、`ASSETCATALOG_COMPILER_OPTIMIZATION=space` 以及 `zip -9` 极限压缩。
- **实测核心引擎体积**：`OpenSourceHubCore` 编译裁剪后仅 **~744 KB**，预计最终 `.ipa` 体积约 **1–2 MB**。

## 已包含的全部核心功能

- **软件源管理（LCSign 竖屏风格）**：支持单个/批量导入（`owner/repo`、HTTPS URL、SSH 地址）、分类文件夹筛选、搜索、随时下拉刷新与右上角一键全量刷新、长按快捷菜单。
- **四通道版本同步引擎**：GitHub Releases + Assets 附件（自动识别平台/架构/文件类型与 SHA256）、Git Tags、默认分支 Commits、Changelog/版本文件/README/Logo；首次同步建立历史基线不打扰；SQLite 持久化 HTTP ETag / Last-Modified（304 缓存省额度）。
- **跨仓库软件发现**：按平台（iOS / macOS / Windows / Linux / Android / 跨平台）、架构、格式搜索全部已同步安装包，一键跳转下载或系统分享。
- **社区数据**：内置仓库 Issues（REST）与 Discussions（GraphQL）同步与正文 Markdown 阅读。
- **全渠道更新通知**：iOS 本地推送 + Telegram / Discord / 企业微信 / 飞书（HMAC-SHA256 签名）/ QQ 官方群机器人 / 通用 Webhook，均支持一键发送测试。
- **备份与存储管理**：支持 JSON 导出/导入软件源与设置、查看 SQLite 与 ETag 缓存占用并一键清理压缩。

## 如何自动构建 `.ipa`（免本地安装 Xcode）

本仓库已配置 GitHub Actions 工作流 `.github/workflows/build-ios-ipa.yml`（运行在免费的 `macos-15` Runner 上）：

1. 将当前项目推送到你的 GitHub 仓库（公开或私有仓库均可）。
2. 打开 GitHub 仓库的 **Actions** 页面 → 选择 **Build iOS IPA (OpenSource Hub)** → 点击 **Run workflow**（或推送 `ios/` 变更自动触发）。
3. 等待约 2–3 分钟构建完成后，在本次运行页面的 **Artifacts** 区域下载 `OpenSourceHub-iOS-1.0.0-ipa`，解压即得 `OpenSourceHub-iOS-1.0.0-unsigned.ipa`。

## 在 iPhone 上安装 `.ipa`

- **TrollStore（巨魔）**：直接导入 `.ipa` 永久安装，无需签名。
- **AltStore / SideStore / Sideloadly / LCSign**：导入 `.ipa` 使用你的 Apple ID 或个人证书签名安装。

## 本地构建（若已安装 Xcode）

```bash
brew install xcodegen
./ios/build-ipa.sh
# 产物位于 dist/OpenSourceHub-iOS-1.0.0-unsigned.ipa
```
