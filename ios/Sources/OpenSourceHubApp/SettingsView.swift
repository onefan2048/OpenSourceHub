import SwiftUI
import UIKit
import UniformTypeIdentifiers
import OpenSourceHubCore

struct SettingsView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    // Requirement 9: Theme Switcher (Light / Dark / System)
                    NavigationLink {
                        ThemeSettingsView()
                    } label: {
                        settingsCardRow(
                            icon: "paintpalette.fill",
                            title: "软件主题",
                            subtitle: themeSubtitle
                        )
                    }
                    .buttonStyle(.plain)

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
                            subtitle: "轮询 \(app.settings["poll.defaultIntervalMinutes"] ?? "60") 分钟 · 并发 \(app.settings["worker.concurrency"] ?? "2") · 社区每批 \(app.settings["community.pagesPerRun"] ?? "5") 页"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        NotificationChannelsSettingsView()
                    } label: {
                        settingsCardRow(
                            icon: "bell.badge.fill",
                            title: "通知渠道",
                            subtitle: "站内推送、邮件 SMTP、Telegram、Discord、企微、飞书、QQ、Webhook"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        CategoriesSheet()
                    } label: {
                        settingsCardRow(
                            icon: "folder.fill",
                            title: "多级分类管理",
                            subtitle: "已创建 \(app.categories.count) 个分类（支持多级子分类）"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        BackupRestoreView()
                    } label: {
                        settingsCardRow(
                            icon: "externaldrive.fill",
                            title: "备份与还原",
                            subtitle: "导出或导入软件源列表、多级分类与全局设置（JSON）"
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
                            subtitle: "OpenSource Hub iOS 3.0.0 · 原生独立离线版"
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

    private var themeSubtitle: String {
        switch app.settings["ui.theme"] {
        case "light": return "当前：浅色模式"
        case "dark": return "当前：深色模式"
        default: return "当前：跟随系统（自动切换深浅色）"
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

// MARK: - Requirement 9: Theme Settings View

private struct ThemeSettingsView: View {
    @EnvironmentObject private var app: AppStore
    @State private var selectedTheme = "system"

    var body: some View {
        Form {
            Section("外观模式") {
                Picker("主题", selection: $selectedTheme) {
                    Text("跟随系统").tag("system")
                    Text("浅色模式").tag("light")
                    Text("深色模式").tag("dark")
                }
                .pickerStyle(.inline)
                .onChange(of: selectedTheme) { val in
                    app.saveSetting("ui.theme", value: val)
                }
            }
        }
        .navigationTitle("软件主题")
        .onAppear { selectedTheme = app.settings["ui.theme"] ?? "system" }
    }
}

// MARK: - GitHub Token

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

// MARK: - Requirement 1: Sync & Polling Policy (Aligned with Docker)

private struct SyncPolicySettingsView: View {
    @EnvironmentObject private var app: AppStore
    @State private var pollMinutes = 60
    @State private var initialCommits = 30
    @State private var maxReleasePages = 20
    @State private var maxTagPages = 10
    @State private var tagDateBackfill = 5
    @State private var concurrency = 2
    @State private var communityInterval = 30
    @State private var communityPagesPerRun = 5
    @State private var staleDays = 365

    var body: some View {
        Form {
            Section("自动轮询与并发") {
                Picker("默认轮询间隔", selection: $pollMinutes) {
                    ForEach(HubSettings.pollIntervals, id: \.self) { m in
                        Text(m >= 60 ? "\(m / 60) 小时" : "\(m) 分钟").tag(m)
                    }
                }
                Stepper("并发同步数: \(concurrency)", value: $concurrency, in: 1...6)
                Stepper("首次导入 Commit 数量: \(initialCommits)", value: $initialCommits, in: 5...200, step: 5)
            }

            Section("历史抓取与 Tag 时间补全") {
                Stepper("Release 分页上限: \(maxReleasePages)", value: $maxReleasePages, in: 1...100)
                Stepper("Tag 分页上限: \(maxTagPages)", value: $maxTagPages, in: 1...100)
                Stepper("每次补全 Tag 时间数量: \(tagDateBackfill)", value: $tagDateBackfill, in: 0...50)
                Stepper("长期未更新判定天数: \(staleDays)", value: $staleDays, in: 30...1095, step: 30)
            }

            Section("Issues / Discussions 社区同步") {
                Stepper("增量同步间隔: \(communityInterval) 分钟", value: $communityInterval, in: 5...1440, step: 5)
                Stepper("每批回填页数（防卡顿）: \(communityPagesPerRun)", value: $communityPagesPerRun, in: 1...20)
            }

            Section {
                Button("保存配置") {
                    app.saveSetting("poll.defaultIntervalMinutes", value: String(pollMinutes))
                    app.saveSetting("sync.initialCommitCount", value: String(initialCommits))
                    app.saveSetting("sync.maxReleasePages", value: String(maxReleasePages))
                    app.saveSetting("sync.maxTagPages", value: String(maxTagPages))
                    app.saveSetting("sync.tagDateBackfillPerSync", value: String(tagDateBackfill))
                    app.saveSetting("worker.concurrency", value: String(concurrency))
                    app.saveSetting("community.intervalMinutes", value: String(communityInterval))
                    app.saveSetting("community.pagesPerRun", value: String(communityPagesPerRun))
                    app.saveSetting("sync.staleDays", value: String(staleDays))
                    app.showToast("已保存同步配置")
                }
                .fontWeight(.semibold)
                .foregroundStyle(HubTheme.accent)
            }
        }
        .navigationTitle("同步与轮询配置")
        .onAppear {
            pollMinutes = Int(app.settings["poll.defaultIntervalMinutes"] ?? "") ?? 60
            initialCommits = Int(app.settings["sync.initialCommitCount"] ?? "") ?? 30
            maxReleasePages = Int(app.settings["sync.maxReleasePages"] ?? "") ?? 20
            maxTagPages = Int(app.settings["sync.maxTagPages"] ?? "") ?? 10
            tagDateBackfill = Int(app.settings["sync.tagDateBackfillPerSync"] ?? "") ?? 5
            concurrency = Int(app.settings["worker.concurrency"] ?? "") ?? 2
            communityInterval = Int(app.settings["community.intervalMinutes"] ?? "") ?? 30
            communityPagesPerRun = Int(app.settings["community.pagesPerRun"] ?? "") ?? 5
            staleDays = Int(app.settings["sync.staleDays"] ?? "") ?? 365
        }
    }
}

// MARK: - Requirement 2: Notification Channels (Including SMTP Email!)

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

    // Email SMTP fields (aligned with Docker)
    @State private var emailProvider = "qq"
    @State private var emailTo = ""
    @State private var emailUsername = ""
    @State private var emailPassword = ""
    @State private var emailHost = "smtp.qq.com"
    @State private var emailPort = "465"
    @State private var emailSecurity = "tls"
    @State private var outlookClientId = ""
    @State private var outlookRefreshToken = ""

    @State private var testing = false

    var body: some View {
        Form {
            Section("本机通知") {
                Toggle("启用站内与 iOS 本地推送通知", isOn: $localEnabled)
            }

            Section {
                Picker("邮件服务商", selection: $emailProvider) {
                    Text("QQ 邮箱").tag("qq")
                    Text("163 邮箱").tag("163")
                    Text("Gmail").tag("gmail")
                    Text("Outlook (OAuth2)").tag("outlook")
                    Text("自定义 SMTP").tag("custom")
                }
                .onChange(of: emailProvider) { prov in
                    switch prov {
                    case "qq": emailHost = "smtp.qq.com"; emailPort = "465"; emailSecurity = "tls"
                    case "163": emailHost = "smtp.163.com"; emailPort = "465"; emailSecurity = "tls"
                    case "gmail": emailHost = "smtp.gmail.com"; emailPort = "465"; emailSecurity = "tls"
                    case "outlook": emailHost = "smtp.office365.com"; emailPort = "587"; emailSecurity = "starttls"
                    default: break
                    }
                }
                TextField("收件邮箱", text: $emailTo)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("发件邮箱（SMTP 用户名）", text: $emailUsername)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if emailProvider == "outlook" {
                    TextField("Outlook Client ID", text: $outlookClientId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Outlook Refresh Token", text: $outlookRefreshToken)
                } else {
                    SecureField("SMTP 授权码 / 密码", text: $emailPassword)
                }
                TextField("SMTP 服务器", text: $emailHost)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("SMTP 端口", text: $emailPort)
                    .keyboardType(.numberPad)
                Picker("加密方式", selection: $emailSecurity) {
                    Text("TLS (推荐 465)").tag("tls")
                    Text("STARTTLS (587)").tag("starttls")
                }
                testButton("email", label: "发送测试邮件")
            } header: {
                Text("邮件通知 (SMTP)")
            } footer: {
                Text("QQ / 163 / Gmail 请填写邮箱授权码并使用 465 端口 TLS 加密。")
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

            emailProvider = app.settings["notify.email.provider"] ?? "qq"
            emailTo = app.settings["notify.email.to"] ?? ""
            emailUsername = app.settings["notify.email.username"] ?? ""
            emailPassword = app.settings["notify.email.password"] ?? ""
            emailHost = app.settings["notify.email.host"] ?? "smtp.qq.com"
            emailPort = app.settings["notify.email.port"] ?? "465"
            emailSecurity = app.settings["notify.email.security"] ?? "tls"
            outlookClientId = app.settings["notify.email.outlook.clientId"] ?? ""
            outlookRefreshToken = app.settings["notify.email.outlook.refreshToken"] ?? ""
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

        app.saveSetting("notify.email.provider", value: emailProvider)
        app.saveSetting("notify.email.to", value: emailTo.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.email.username", value: emailUsername.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.email.password", value: emailPassword)
        app.saveSetting("notify.email.host", value: emailHost.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.email.port", value: emailPort.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.email.security", value: emailSecurity)
        app.saveSetting("notify.email.outlook.clientId", value: outlookClientId.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("notify.email.outlook.refreshToken", value: outlookRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func testButton(_ channel: String, label: String = "发送测试消息") -> some View {
        Button(testing ? "发送中…" : label) {
            saveAll()
            testing = true
            Task {
                do {
                    try await NotificationDispatcher.sendTest(channel: channel, settings: app.settings, store: app.store)
                    app.showToast("\(channel.uppercased()) 测试发送成功")
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

// MARK: - Backup, Storage & About

private struct BackupRestoreView: View {
    @EnvironmentObject private var app: AppStore
    @State private var shareURL: URL?
    @State private var showImporter = false

    var body: some View {
        Form {
            Section("导出备份") {
                Button {
                    do {
                        let data = try app.store.exportBackupJSON()
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenSourceHub-Backup.json")
                        try data.write(to: url, options: .atomic)
                        shareURL = url
                    } catch {
                        app.showToast("导出失败: \(error.localizedDescription)")
                    }
                } label: {
                    Label("导出配置与软件源列表 (JSON)", systemImage: "square.and.arrow.up")
                        .foregroundStyle(HubTheme.accent)
                }

                Button {
                    do {
                        let data = try app.store.exportBackupJSON()
                        UIPasteboard.general.string = String(data: data, encoding: .utf8)
                        app.showToast("已复制备份 JSON 到剪贴板")
                    } catch {
                        app.showToast("复制失败: \(error.localizedDescription)")
                    }
                } label: {
                    Label("复制备份 JSON 到剪贴板", systemImage: "doc.on.doc")
                        .foregroundStyle(HubTheme.accent)
                }
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("从本地 JSON 文件还原…", systemImage: "folder.badge.plus")
                        .foregroundStyle(HubTheme.accent)
                }

                Button {
                    guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty,
                          let data = text.data(using: .utf8) else {
                        app.showToast("剪贴板中没有 JSON 内容")
                        return
                    }
                    do {
                        let count = try app.store.importBackupJSON(data)
                        app.reloadAll()
                        app.showToast("已从剪贴板还原（新增 \(count) 个软件源）")
                    } catch {
                        app.showToast("剪贴板 JSON 解析失败: \(error.localizedDescription)")
                    }
                } label: {
                    Label("从剪贴板 JSON 还原", systemImage: "doc.on.clipboard")
                }
            } header: {
                Text("还原备份")
            } footer: {
                Text("备份文件包含软件源列表、多级分类结构与全部设置项，支持直接从「文件」App 任意目录或剪贴板导入。")
            }
        }
        .navigationTitle("备份与还原")
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let u = shareURL { ShareSheet(items: [u]) }
        }
        .sheet(isPresented: $showImporter) {
            BackupJSONDocumentPicker { result in
                switch result {
                case let .success(data):
                    do {
                        let count = try app.store.importBackupJSON(data)
                        app.reloadAll()
                        app.showToast("还原成功（新增 \(count) 个软件源）")
                    } catch {
                        app.showToast("JSON 解析失败: \(error.localizedDescription)")
                    }
                case let .failure(err):
                    app.showToast("读取文件失败: \(err.localizedDescription)")
                }
            }
        }
    }
}

/// Native UIDocumentPickerViewController with `asCopy: true` and broad content types `[.json, .plainText, .text, .data, .item]`
/// so `.json` files stored in third-party signer containers or iOS Files folders are NEVER grayed out.
private struct BackupJSONDocumentPicker: UIViewControllerRepresentable {
    var onCompletion: (Result<Data, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.json, .plainText, .text, .data, .item]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompletion: (Result<Data, Error>) -> Void

        init(onCompletion: @escaping (Result<Data, Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                onCompletion(.success(data))
            } catch {
                onCompletion(.failure(error))
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
                LabeledContent("版本", value: "3.0.0 (iOS 独立版)")
                LabeledContent("架构", value: "纯 SwiftUI + WebKit + 系统 SQLite3")
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
