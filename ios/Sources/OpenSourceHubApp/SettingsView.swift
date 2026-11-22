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
                    // Theme Switcher
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

                    // Requirement 2: Multi-Account GitHub Management & Reply Tracking
                    NavigationLink {
                        GitHubAccountsManageView()
                    } label: {
                        settingsCardRow(
                            icon: "person.2.badge.key.fill",
                            title: "GitHub 账号管理（支持多账号）",
                            subtitle: accountsSubtitle
                        )
                    }
                    .buttonStyle(.plain)

                    // Requirement 1: Backup, Restore & Cloud Sync (WebDAV / GitHub Gist)
                    NavigationLink {
                        BackupAndCloudSyncView()
                    } label: {
                        settingsCardRow(
                            icon: "icloud.and.arrow.up.fill",
                            title: "备份还原与数据云同步",
                            subtitle: cloudSubtitle
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
                            subtitle: "OpenSource Hub iOS 4.0.0 · 原生独立离线版"
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

    private var accountsSubtitle: String {
        if app.githubAccounts.isEmpty {
            let hasLegacy = !(app.settings["github.token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasLegacy ? "已配置默认令牌 · 点击登录多账号追踪 Issue/Discussion 回复" : "登录一个或多个 GitHub 账号，追踪你发起的 Issue & Discussion 回复"
        }
        let logins = app.githubAccounts.map { "@\($0.login)" }.joined(separator: "、")
        return "已登录 \(app.githubAccounts.count) 个账号（\(logins)）· 未读回复 \(app.stats.unreadAccountNotifications) 条"
    }

    private var cloudSubtitle: String {
        let status = (app.settings["cloud.lastStatus"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty { return status }
        return "支持 WebDAV / 私密 GitHub Gist 跨设备双向云同步（AES-256-GCM 加密）与本地 JSON 备份"
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

// MARK: - Requirement 2: Multi-Account GitHub Management View

struct GitHubAccountsManageView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme
    @State private var tokenInput = ""
    @State private var showToken = false
    @State private var loggingIn = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                // Login / Add Account Card
                VStack(alignment: .leading, spacing: 10) {
                    Text("GitHub 账号管理（支持多账号）")
                        .font(.headline)
                    Text("登录你的一个或多个 GitHub 账号后，系统会自动追踪这些账号对任意项目发起的 Issue 或 Discussion 所收到的他人回复，并在「通知 → 我的 Issue & Discussion 回复」板块中独立展示。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Group {
                            if showToken {
                                TextField("输入 GitHub Personal Access Token (ghp_... / github_pat_...)", text: $tokenInput)
                            } else {
                                SecureField("输入 GitHub Personal Access Token (ghp_... / github_pat_...)", text: $tokenInput)
                            }
                        }
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.subheadline)

                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(spacing: 10) {
                        Button {
                            loginAccount()
                        } label: {
                            Label(loggingIn ? "验证中…" : "登录 / 添加账号", systemImage: "person.badge.plus")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(HubTheme.accent)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(loggingIn || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if !app.githubAccounts.isEmpty {
                            Button {
                                Task { await app.syncAccountReplies(accountId: nil) }
                            } label: {
                                Label(app.isSyncingAccounts ? "同步中…" : "同步全部回复", systemImage: "arrow.clockwise")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(HubTheme.accentSoft)
                                    .foregroundStyle(HubTheme.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .disabled(app.isSyncingAccounts)
                        }
                    }
                }
                .hubCard()

                // Logged-in Accounts List
                if app.githubAccounts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("尚未登录 GitHub 账号")
                            .font(.subheadline.weight(.semibold))
                        Text("上方输入 PAT 登录后，同时可将 GitHub API 速率上限从 60 次/小时提升至 5,000 次/小时。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .hubCard(padding: 24)
                } else {
                    ForEach(app.githubAccounts) { acc in
                        accountRow(acc)
                    }
                }

                if let rem = app.rateLimit.remaining, let lim = app.rateLimit.limit {
                    HStack {
                        Text("当前观察到的 API 额度：\(rem) / \(lim)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let reset = app.rateLimit.resetAt {
                            Text("重置：\(DateFmt.shortDateTime(reset))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(16)
        }
        .background(HubTheme.canvas(scheme).ignoresSafeArea())
        .navigationTitle("GitHub 账号管理")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loginAccount() {
        let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loggingIn = true
        Task {
            do {
                try await app.loginGitHubAccount(token: trimmed)
                tokenInput = ""
            } catch {
                app.showToast(error.localizedDescription)
            }
            loggingIn = false
        }
    }

    private func accountRow(_ acc: GitHubAccountItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let av = acc.avatarUrl, let url = URL(string: av) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            Circle().fill(HubTheme.accentSoft)
                        }
                    }
                    .frame(width: 42, height: 42)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(HubTheme.accentSoft)
                        .frame(width: 42, height: 42)
                        .overlay(Text(String(acc.login.prefix(1)).uppercased()).font(.headline).foregroundStyle(HubTheme.accent))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("@\(acc.login)")
                            .font(.body.weight(.bold))
                        if acc.isDefault {
                            Text("默认账号")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(HubTheme.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(HubTheme.accentSoft)
                                .clipShape(Capsule())
                        }
                        if !acc.enabled {
                            Text("已暂停")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }
                    Text("未读回复 \(acc.unreadCount) 条 / 共 \(acc.totalCount) 条 · 凭证 \(acc.tokenMasked) · 上次同步 \(DateFmt.relative(acc.lastSyncedAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let err = acc.lastError, !err.isEmpty {
                Text("同步异常：\(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                if !acc.isDefault {
                    Button("设为默认") {
                        app.setDefaultGitHubAccount(id: acc.id)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundStyle(.primary)
                    .clipShape(Capsule())
                }

                Button(acc.enabled ? "暂停通知" : "恢复通知") {
                    app.toggleGitHubAccountEnabled(id: acc.id, enabled: !acc.enabled)
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12))
                .foregroundStyle(.primary)
                .clipShape(Capsule())

                Button {
                    Task { await app.syncAccountReplies(accountId: acc.id) }
                } label: {
                    Label("同步", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(HubTheme.accentSoft)
                        .foregroundStyle(HubTheme.accent)
                        .clipShape(Capsule())
                }
                .disabled(app.isSyncingAccounts)

                Spacer()

                Button(role: .destructive) {
                    app.removeGitHubAccount(id: acc.id)
                } label: {
                    Label("退出", systemImage: "trash")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.12))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                }
            }
        }
        .hubCard(padding: 14, radius: 18)
    }
}

// MARK: - Requirement 1: Backup, Restore & Cloud Sync View (WebDAV / GitHub Gist + AES-256-GCM)

private struct BackupAndCloudSyncView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme

    @State private var provider = "webdav" // webdav | gist
    @State private var webdavUrl = ""
    @State private var webdavUsername = ""
    @State private var webdavPassword = ""
    @State private var gistToken = ""
    @State private var gistId = ""
    @State private var passphrase = ""
    @State private var autoSync = false
    @State private var showPassphrase = false
    @State private var showSecret = false

    @State private var shareURL: URL?
    @State private var showImporter = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                // 1. 数据云同步 Card (Matches Docker Screenshot)
                VStack(alignment: .leading, spacing: 12) {
                    Text("数据云同步")
                        .font(.headline)
                    Text("支持通过 WebDAV 或私密 GitHub Gist 跨设备同步。如果服务器已存在其他客户端（如 Mac / Docker）同步的数据，首次同步将自动拉取并合并本地配置，后续则根据修改时间自动更新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Provider selector cards
                    HStack(spacing: 10) {
                        providerCard(
                            id: "webdav",
                            icon: "icloud",
                            title: "WebDAV",
                            desc: "Nextcloud、坚果云、Koofr 等 WebDAV 服务"
                        )
                        providerCard(
                            id: "gist",
                            icon: "chevron.left.forwardslash.chevron.right",
                            title: "GitHub Gist",
                            desc: "私密 GitHub Gist"
                        )
                    }

                    if provider == "webdav" {
                        labeledInput("同步接口") {
                            TextField("https://app.koofr.net/dav/Koofr/OpenSourceHub_Mac", text: $webdavUrl)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        labeledInput("同步账户") {
                            TextField("WebDAV 用户名 / 邮箱", text: $webdavUsername)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        labeledInput("同步密钥") {
                            HStack {
                                if showSecret {
                                    TextField("WebDAV 应用密码", text: $webdavPassword)
                                } else {
                                    SecureField("WebDAV 应用密码", text: $webdavPassword)
                                }
                                Button { showSecret.toggle() } label: {
                                    Image(systemName: showSecret ? "eye.slash" : "eye").foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        labeledInput("Gist 同步密钥（留空则复用默认 GitHub 账号令牌）") {
                            HStack {
                                if showSecret {
                                    TextField("具备 gist 权限的 Personal Access Token", text: $gistToken)
                                } else {
                                    SecureField("具备 gist 权限的 Personal Access Token", text: $gistToken)
                                }
                                Button { showSecret.toggle() } label: {
                                    Image(systemName: showSecret ? "eye.slash" : "eye").foregroundStyle(.secondary)
                                }
                            }
                        }
                        labeledInput("私密 Gist ID（可选，首次同步自动查找或创建）") {
                            TextField("自动填充", text: $gistId)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }

                    labeledInput("加密口令（可选，设置后云端数据采用 AES-256-GCM 加密）") {
                        HStack {
                            if showPassphrase {
                                TextField("跨设备同步须使用相同加密口令", text: $passphrase)
                            } else {
                                SecureField("跨设备同步须使用相同加密口令", text: $passphrase)
                            }
                            Button { showPassphrase.toggle() } label: {
                                Image(systemName: showPassphrase ? "eye.slash" : "eye").foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !passphrase.isEmpty {
                        Button("清除本地口令") {
                            passphrase = ""
                            app.saveSetting("cloud.passphrase", value: "")
                            app.showToast("已清除本地加密口令")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(HubTheme.accent)
                    }

                    Toggle(isOn: $autoSync) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动同步").font(.subheadline.weight(.semibold))
                            Text("开启后后台每 10 分钟自动与云端保持同步")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: autoSync) { val in
                        app.saveSetting("cloud.autoSync", value: val ? "true" : "false")
                    }

                    // Status banner
                    if let status = app.settings["cloud.lastStatus"], !status.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: status.contains("失败") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(status.contains("失败") ? .red : HubTheme.accent)
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(status.contains("失败") ? .red : HubTheme.accent)
                            Spacer()
                        }
                        .padding(10)
                        .background((status.contains("失败") ? Color.red : HubTheme.accent).opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    // Cloud Sync Action Buttons
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button {
                                saveCloudSettings()
                                Task { await app.performCloudSync(direction: "auto") }
                            } label: {
                                Label(app.isCloudSyncing ? "同步中…" : "立即同步", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(HubTheme.accent)
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .disabled(app.isCloudSyncing)

                            Button {
                                saveCloudSettings()
                                Task { await app.performCloudSync(direction: "push") }
                            } label: {
                                Label("上传云端", systemImage: "icloud.and.arrow.up")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(Color.secondary.opacity(0.12))
                                    .foregroundStyle(.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .disabled(app.isCloudSyncing)

                            Button {
                                saveCloudSettings()
                                Task { await app.performCloudSync(direction: "pull") }
                            } label: {
                                Label("从云端恢复", systemImage: "icloud.and.arrow.down")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(Color.secondary.opacity(0.12))
                                    .foregroundStyle(.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .disabled(app.isCloudSyncing)
                        }
                    }
                }
                .hubCard()

                // 2. 本地备份与还原 Card
                VStack(alignment: .leading, spacing: 10) {
                    Text("本地备份与还原")
                        .font(.headline)
                    Text("备份文件包含软件源列表、多级分类结构、项目备注、已登录账号与全部设置项，支持直接从本地文件或剪贴板导入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        saveCloudSettings()
                        do {
                            let data = try app.store.exportBackupJSON(passphrase: passphrase)
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("opensource-hub-backup.json")
                            try data.write(to: url, options: .atomic)
                            shareURL = url
                        } catch {
                            app.showToast("导出失败: \(error.localizedDescription)")
                        }
                    } label: {
                        actionRow(icon: "square.and.arrow.up", title: "导出配置与软件源列表 (JSON)")
                    }
                    .buttonStyle(.plain)

                    Button {
                        saveCloudSettings()
                        do {
                            let data = try app.store.exportBackupJSON(passphrase: passphrase)
                            UIPasteboard.general.string = String(data: data, encoding: .utf8)
                            app.showToast("已复制备份 JSON 到剪贴板")
                        } catch {
                            app.showToast("复制失败: \(error.localizedDescription)")
                        }
                    } label: {
                        actionRow(icon: "doc.on.doc", title: "复制备份 JSON 到剪贴板")
                    }
                    .buttonStyle(.plain)

                    Divider()

                    Button {
                        saveCloudSettings()
                        showImporter = true
                    } label: {
                        actionRow(icon: "folder.badge.plus", title: "从本地 JSON 文件还原…")
                    }
                    .buttonStyle(.plain)

                    Button {
                        saveCloudSettings()
                        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !text.isEmpty,
                              let data = text.data(using: .utf8) else {
                            app.showToast("剪贴板中没有 JSON 内容")
                            return
                        }
                        do {
                            let res = try CloudBackupEngine.importJSONData(store: app.store, data: data, passphrase: passphrase)
                            app.reloadAll()
                            app.showToast("已从剪贴板还原（新增 \(res.addedRepos) 个、更新 \(res.updatedRepos) 个软件源）")
                        } catch {
                            app.showToast("还原失败: \(error.localizedDescription)")
                        }
                    } label: {
                        actionRow(icon: "doc.on.clipboard", title: "从剪贴板 JSON 还原")
                    }
                    .buttonStyle(.plain)
                }
                .hubCard()
            }
            .padding(16)
        }
        .background(HubTheme.canvas(scheme).ignoresSafeArea())
        .navigationTitle("备份与数据云同步")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadCloudSettings() }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let u = shareURL { ShareSheet(items: [u]) }
        }
        .sheet(isPresented: $showImporter) {
            BackupJSONDocumentPicker { result in
                switch result {
                case let .success(data):
                    do {
                        let res = try CloudBackupEngine.importJSONData(store: app.store, data: data, passphrase: passphrase)
                        app.reloadAll()
                        app.showToast("还原成功（新增 \(res.addedRepos) 个、更新 \(res.updatedRepos) 个软件源）")
                    } catch {
                        app.showToast("还原失败: \(error.localizedDescription)")
                    }
                case let .failure(err):
                    app.showToast("读取文件失败: \(err.localizedDescription)")
                }
            }
        }
    }

    private func loadCloudSettings() {
        provider = app.settings["cloud.provider"] ?? "webdav"
        webdavUrl = app.settings["cloud.webdav.url"] ?? ""
        webdavUsername = app.settings["cloud.webdav.username"] ?? ""
        webdavPassword = app.settings["cloud.webdav.password"] ?? ""
        gistToken = app.settings["cloud.gist.token"] ?? ""
        gistId = app.settings["cloud.gist.id"] ?? ""
        passphrase = app.settings["cloud.passphrase"] ?? ""
        autoSync = app.settings["cloud.autoSync"] == "true"
    }

    private func saveCloudSettings() {
        app.saveSetting("cloud.provider", value: provider)
        app.saveSetting("cloud.webdav.url", value: webdavUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("cloud.webdav.username", value: webdavUsername.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("cloud.webdav.password", value: webdavPassword)
        app.saveSetting("cloud.gist.token", value: gistToken.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("cloud.gist.id", value: gistId.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("cloud.passphrase", value: passphrase.trimmingCharacters(in: .whitespacesAndNewlines))
        app.saveSetting("cloud.autoSync", value: autoSync ? "true" : "false")
    }

    private func providerCard(id: String, icon: String, title: String, desc: String) -> some View {
        let active = provider == id
        return Button {
            provider = id
            app.saveSetting("cloud.provider", value: id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(active ? HubTheme.accent : .secondary)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(active ? HubTheme.accentSoft : Color.secondary.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(active ? HubTheme.accent : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func labeledInput<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func actionRow(icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(HubTheme.accent)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(HubTheme.accent)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HubTheme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Native UIDocumentPickerViewController with `asCopy: true` and broad content types `[.json, .plainText, .text, .data, .item]`
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

// MARK: - Theme Settings View

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

// MARK: - Sync & Polling Policy

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

// MARK: - Notification Channels

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

// MARK: - Storage & About

private struct StorageSettingsView: View {
    @EnvironmentObject private var app: AppStore

    var body: some View {
        Form {
            Section("本地占用") {
                LabeledContent("SQLite 数据库", value: AssetClassifier.formatBytes(app.stats.databaseBytes))
                LabeledContent("HTTP ETag 缓存", value: AssetClassifier.formatBytes(app.stats.cacheBytes))
                LabeledContent("已订阅软件源", value: "\(app.stats.totalRepos) 个")
                LabeledContent("已索引软件包", value: "\(app.stats.totalSoftwareAssets) 个")
                LabeledContent("已登录 GitHub 账号", value: "\(app.githubAccounts.count) 个")
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
                LabeledContent("版本", value: "4.0.0 (iOS 独立版)")
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
