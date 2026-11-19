import SwiftUI
import UniformTypeIdentifiers
import OpenSourceHubCore

struct SettingsView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme

    @State private var showExporter = false
    @State private var showImporter = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    NavigationLink {
                        GitHubTokenSettingsView()
                    } label: {
                        settingsCardRow(
                            icon: "key.fill",
                            title: "GitHub 令牌",
                            subtitle: tokenSubtitle
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        SyncPolicySettingsView()
                    } label: {
                        settingsCardRow(
                            icon: "arrow.triangle.2.circlepath",
                            title: "同步与轮询配置",
                            subtitle: "默认每 \(app.settings["poll.defaultIntervalMinutes"] ?? "15") 分钟检查更新、分页与基线策略"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        NotificationChannelsSettingsView()
                    } label: {
                        settingsCardRow(
                            icon: "bell.badge.fill",
                            title: "通知渠道",
                            subtitle: "iOS 本地推送、Telegram、Discord、企微、飞书、QQ、Webhook"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        CategoriesSheet()
                    } label: {
                        settingsCardRow(
                            icon: "folder.fill",
                            title: "分类管理",
                            subtitle: "已创建 \(app.categories.count) 个软件源分类"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        BackupRestoreView()
                    } label: {
                        settingsCardRow(
                            icon: "externaldrive.fill",
                            title: "备份与还原",
                            subtitle: "导出或导入软件源列表、分类与全局设置（JSON）"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        StorageSettingsView()
                    } label: {
                        settingsCardRow(
                            icon: "internaldrive.fill",
                            title: "存储空间",
                            subtitle: "数据库 \(AssetClassifier.formatBytes(app.stats.databaseBytes)) · ETag 缓存 \(AssetClassifier.formatBytes(app.stats.cacheBytes))"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        AboutAndLogsView()
                    } label: {
                        settingsCardRow(
                            icon: "info.circle.fill",
                            title: "关于与同步日志",
                            subtitle: "OpenSource Hub iOS 1.0.0 · 原生独立离线版"
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(HubTheme.canvas(scheme).ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var tokenSubtitle: String {
        let hasToken = !(app.settings["github.token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let rem = app.rateLimit.remaining, let lim = app.rateLimit.limit {
            return "\(hasToken ? "已配置令牌" : "匿名模式") · 剩余额度 \(rem)/\(lim)"
        }
        return hasToken ? "已配置令牌（最高 5,000 次/小时）" : "提高 GitHub API 速率上限（当前匿名 60 次/小时）"
    }

    private func settingsCardRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(HubTheme.accent)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .hubCard(padding: 16, radius: 20)
    }
}

// MARK: - Subpages

private struct GitHubTokenSettingsView: View {
    @EnvironmentObject private var app: AppStore
    @State private var token: String = ""

    var body: some View {
        Form {
            Section {
                SecureField("ghp_xxxxxxxxxxxxxxxx", text: $token)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("保存令牌") {
                    app.saveSetting("github.token", value: token.trimmingCharacters(in: .whitespacesAndNewlines))
                    app.showToast("已保存 GitHub 令牌")
                }
                .foregroundStyle(HubTheme.accent)
            } header: {
                Text("Personal Access Token")
            } footer: {
                Text("未配置令牌时匿名访问公开仓库额度为 60 次/小时；配置后提升至 5,000 次/小时，并支持同步 Discussions 与私有仓库。")
            }

            if let rem = app.rateLimit.remaining, let lim = app.rateLimit.limit {
                Section("当前 API 额度") {
                    LabeledContent("剩余 / 上限", value: "\(rem) / \(lim)")
                    if let reset = app.rateLimit.resetAt {
                        LabeledContent("重置时间", value: DateFmt.shortDateTime(reset))
                    }
                }
            }
        }
        .navigationTitle("GitHub 令牌")
        .onAppear { token = app.settings["github.token"] ?? "" }
    }
}

private struct SyncPolicySettingsView: View {
    @EnvironmentObject private var app: AppStore
    @State private var pollMinutes = 15
    @State private var maxReleasePages = 10
    @State private var maxTagPages = 5
    @State private var initialCommits = 30

    var body: some View {
        Form {
            Section("自动刷新间隔") {
                Picker("默认间隔", selection: $pollMinutes) {
                    ForEach(HubSettings.pollIntervals, id: \.self) { m in
                        Text(m >= 60 ? "\(m / 60) 小时" : "\(m) 分钟").tag(m)
                    }
                }
            }

            Section("历史抓取上限") {
                Stepper("Release 最大页数: \(maxReleasePages)", value: $maxReleasePages, in: 1...30)
                Stepper("Tag 最大页数: \(maxTagPages)", value: $maxTagPages, in: 1...20)
                Stepper("首次 Commit 条数: \(initialCommits)", value: $initialCommits, in: 10...100, step: 10)
            }

            Section {
                Button("保存配置") {
                    app.saveSetting("poll.defaultIntervalMinutes", value: String(pollMinutes))
                    app.saveSetting("sync.maxReleasePages", value: String(maxReleasePages))
                    app.saveSetting("sync.maxTagPages", value: String(maxTagPages))
                    app.saveSetting("sync.initialCommitCount", value: String(initialCommits))
                    app.showToast("已保存同步配置")
                }
                .foregroundStyle(HubTheme.accent)
            }
        }
        .navigationTitle("同步与轮询配置")
        .onAppear {
            pollMinutes = Int(app.settings["poll.defaultIntervalMinutes"] ?? "") ?? 15
            maxReleasePages = Int(app.settings["sync.maxReleasePages"] ?? "") ?? 10
            maxTagPages = Int(app.settings["sync.maxTagPages"] ?? "") ?? 5
            initialCommits = Int(app.settings["sync.initialCommitCount"] ?? "") ?? 30
        }
    }
}

private struct NotificationChannelsSettingsView: View {
    @EnvironmentObject private var app: AppStore
    @State private var localEnabled = true
    @State private var tgToken = ""
    @State private var tgChat = ""
    @State private var discordUrl = ""
    @State private var wecomUrl = ""
    @State private var feishuUrl = ""
    @State private var feishuSecret = ""
    @State private var qqAppId = ""
    @State private var qqSecret = ""
    @State private var qqGroup = ""
    @State private var webhookUrl = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("本机通知") {
                Toggle("iOS 本地推送通知", isOn: $localEnabled)
            }
            Section("Telegram") {
                SecureField("Bot Token", text: $tgToken)
                TextField("Chat ID", text: $tgChat)
                testButton("telegram")
            }
            Section("Discord") {
                SecureField("Webhook URL", text: $discordUrl)
                testButton("discord")
            }
            Section("企业微信") {
                SecureField("机器人 Webhook URL", text: $wecomUrl)
                testButton("wecom")
            }
            Section("飞书") {
                SecureField("机器人 Webhook URL", text: $feishuUrl)
                SecureField("签名密钥（可选）", text: $feishuSecret)
                testButton("feishu")
            }
            Section("QQ 官方群机器人") {
                TextField("AppID", text: $qqAppId)
                SecureField("ClientSecret", text: $qqSecret)
                TextField("Group OpenID", text: $qqGroup)
                testButton("qq")
            }
            Section("通用 Webhook") {
                SecureField("Webhook URL", text: $webhookUrl)
                testButton("webhook")
            }
            Section {
                Button("保存全部通知设置") {
                    saveAll()
                    app.showToast("已保存通知设置")
                }
                .fontWeight(.semibold)
                .foregroundStyle(HubTheme.accent)
            }
        }
        .navigationTitle("通知渠道")
        .onAppear {
            localEnabled = app.settings["notify.local.enabled"] != "false"
            tgToken = app.settings["notify.telegram.botToken"] ?? ""
            tgChat = app.settings["notify.telegram.chatId"] ?? ""
            discordUrl = app.settings["notify.discord.webhookUrl"] ?? ""
            wecomUrl = app.settings["notify.wecom.webhookUrl"] ?? ""
            feishuUrl = app.settings["notify.feishu.webhookUrl"] ?? ""
            feishuSecret = app.settings["notify.feishu.secret"] ?? ""
            qqAppId = app.settings["notify.qq.appId"] ?? ""
            qqSecret = app.settings["notify.qq.clientSecret"] ?? ""
            qqGroup = app.settings["notify.qq.groupOpenId"] ?? ""
            webhookUrl = app.settings["notify.webhook.url"] ?? ""
        }
    }

    private func saveAll() {
        app.saveSetting("notify.local.enabled", value: localEnabled ? "true" : "false")
        app.saveSetting("notify.telegram.botToken", value: tgToken.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.telegram.chatId", value: tgChat.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.discord.webhookUrl", value: discordUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.wecom.webhookUrl", value: wecomUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.feishu.webhookUrl", value: feishuUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.feishu.secret", value: feishuSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.qq.appId", value: qqAppId.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.qq.clientSecret", value: qqSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.qq.groupOpenId", value: qqGroup.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.webhook.url", value: webhookUrl.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func testButton(_ channel: String) -> some View {
        Button(testing ? "发送中…" : "发送测试消息") {
            saveAll()
            testing = true
            Task {
                do {
                    try await NotificationDispatcher.sendTest(channel: channel, settings: app.settings)
                    app.showToast("\(channel) 测试发送成功")
                } catch {
                    app.showToast("失败: \(error.localizedDescription)")
                }
                testing = false
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(HubTheme.accent)
        .disabled(testing)
    }
}

private struct BackupRestoreView: View {
    @EnvironmentObject private var app: AppStore
    @State private var shareURL: URL?
    @State private var showImporter = false

    var body: some View {
        Form {
            Section {
                Button("导出配置与软件源列表 (JSON)") {
                    do {
                        let data = try app.store.exportBackupJSON()
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenSourceHub-Backup.json")
                        try data.write(to: url)
                        shareURL = url
                    } catch {
                        app.showToast("导出失败: \(error.localizedDescription)")
                    }
                }
                .foregroundStyle(HubTheme.accent)

                Button("从 JSON 文件还原") {
                    showImporter = true
                }
            } footer: {
                Text("备份文件包含软件源列表、分类结构与设置项，不含本地缓存的 Release 正文，方便在多设备间轻量迁移。")
            }
        }
        .navigationTitle("备份与还原")
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let u = shareURL { ShareSheet(items: [u]) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let count = try app.store.importBackupJSON(data)
                    app.reloadAll()
                    app.showToast("已导入 \(count) 个新软件源")
                } catch {
                    app.showToast("导入失败: \(error.localizedDescription)")
                }
            case let .failure(err):
                app.showToast("选择文件失败: \(err.localizedDescription)")
            }
        }
    }
}

private struct StorageSettingsView: View {
    @EnvironmentObject private var app: AppStore

    var body: some View {
        Form {
            Section("本地占用") {
                LabeledContent("SQLite 数据库", value: AssetClassifier.formatBytes(app.stats.databaseBytes))
                LabeledContent("HTTP ETag 缓存", value: AssetClassifier.formatBytes(app.stats.cacheBytes))
                LabeledContent("已订阅软件源", value: "\(app.stats.totalRepos) 个")
                LabeledContent("已索引软件包", value: "\(app.stats.totalSoftwareAssets) 个")
            }

            Section {
                Button("清理 ETag 缓存并压缩数据库") {
                    app.clearCache()
                }
                .foregroundStyle(HubTheme.accent)
            } footer: {
                Text("清理缓存不会删除软件源和历史版本记录，下次同步时会重新建立 ETag。")
            }
        }
        .navigationTitle("存储空间")
    }
}

private struct AboutAndLogsView: View {
    @EnvironmentObject private var app: AppStore
    @State private var logs: [SyncLogItem] = []

    var body: some View {
        List {
            Section("关于") {
                LabeledContent("应用名称", value: "OpenSource Hub")
                LabeledContent("版本", value: "1.0.0 (iOS 独立版)")
                LabeledContent("架构", value: "纯 SwiftUI + 系统 SQLite3")
            }

            Section("最近同步日志") {
                if logs.isEmpty {
                    Text("暂无同步日志").foregroundStyle(.secondary)
                } else {
                    ForEach(logs) { log in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(log.status.uppercased())
                                    .font(.caption2.bold())
                                    .foregroundStyle(log.status == "success" ? HubTheme.accent : .orange)
                                Text("\(log.durationMs)ms · 请求 \(log.requestCount)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(DateFmt.shortDateTime(log.startedAt)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            if let s = log.summary { Text(s).font(.caption) }
                            if let e = log.error { Text(e).font(.caption2).foregroundStyle(.red) }
                        }
                    }
                }
            }
        }
        .navigationTitle("关于与日志")
        .onAppear {
            logs = app.store.listSyncLogs(repositoryId: nil, limit: 40)
        }
    }
}
