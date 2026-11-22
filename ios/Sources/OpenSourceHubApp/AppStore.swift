import Foundation
import SwiftUI
import UserNotifications
import OpenSourceHubCore

@MainActor
final class AppStore: ObservableObject {
    let store: SQLiteStore

    @Published var repos: [RepositoryItem] = []
    @Published var categories: [CategoryItem] = []
    @Published var categoryTree: [CategoryTreeNode] = []
    @Published var notifications: [NotificationItem] = []
    @Published var githubAccounts: [GitHubAccountItem] = []
    @Published var accountNotifications: [AccountNotificationItem] = []
    @Published var stats: HubStats = .empty
    @Published var settings: [String: String] = HubSettings.defaults
    @Published var rateLimit: RateLimitInfo = RateLimitInfo()

    @Published var syncingRepoIds: Set<Int64> = []
    @Published var isSyncingAll: Bool = false
    @Published var isSyncingAccounts: Bool = false
    @Published var isCloudSyncing: Bool = false
    @Published var syncProgressText: String?
    @Published var toastMessage: String?

    @Published var selectedTab: Int = 0
    @Published var selectedCategoryId: Int64? = nil // nil = all, -1 = uncategorized

    private var autoPollTask: Task<Void, Never>?
    private var bootstrappedDefaultAccount = false
    private var lastAccountSyncAt: Date = .distantPast
    private var lastCloudSyncAt: Date = .distantPast

    var preferredColorScheme: ColorScheme? {
        switch settings["ui.theme"] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("OpenSourceHub", isDirectory: true)
        let dbPath = dbDir.appendingPathComponent("hub.sqlite").path
        do {
            self.store = try SQLiteStore(path: dbPath)
        } catch {
            fatalError("Failed to initialize SQLite database: \(error)")
        }
        reloadAll()
        bootstrapLegacyTokenIfNeeded()
        startForegroundAutoPoll()
    }

    deinit {
        autoPollTask?.cancel()
    }

    func reloadAll() {
        repos = store.listRepositories()
        categories = store.listCategories()
        categoryTree = CategoryTree.build(categories: categories, repos: repos)
        notifications = store.listNotifications(limit: 200)
        githubAccounts = store.listGitHubAccounts()
        accountNotifications = store.listAccountNotifications(limit: 200)
        stats = store.getStats()
        settings = store.getAllSettings()
    }

    private func bootstrapLegacyTokenIfNeeded() {
        guard !bootstrappedDefaultAccount, githubAccounts.isEmpty else { return }
        bootstrappedDefaultAccount = true
        let legacyToken = (settings["github.token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyToken.isEmpty else { return }
        Task {
            if let acc = try? await AccountSyncEngine.loginGitHubAccount(store: store, rawToken: legacyToken, makeDefault: true) {
                _ = await AccountSyncEngine.syncAccountNotifications(store: store, accountId: acc.id)
                reloadAll()
            }
        }
    }

    func categoryPath(for categoryId: Int64?) -> String? {
        guard let cid = categoryId else { return nil }
        return categoryTree.first(where: { $0.id == cid })?.path
    }

    func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if self.toastMessage == message {
                self.toastMessage = nil
            }
        }
    }

    // MARK: - Repositories

    func addRepositories(rawInput: String, categoryId: Int64?) async -> (added: Int, skipped: Int, errors: [String]) {
        let tokens = RepoParser.splitBatchInput(rawInput)
        var addedIds: [Int64] = []
        var skipped = 0
        var errors: [String] = []

        for token in tokens {
            switch RepoParser.parse(token) {
            case let .ok(ref):
                if let pair = store.addRepository(ref, categoryId: categoryId) {
                    if pair.created {
                        addedIds.append(pair.repo.id)
                    } else {
                        skipped += 1
                    }
                }
            case let .error(msg):
                errors.append("\(token): \(msg)")
            }
        }

        reloadAll()
        if !addedIds.isEmpty {
            showToast("已添加 \(addedIds.count) 个软件源，正在同步…")
            for id in addedIds {
                await syncRepo(id: id, trigger: "import", full: true)
            }
        } else if skipped > 0 {
            showToast("已存在 \(skipped) 个软件源")
        }
        return (addedIds.count, skipped, errors)
    }

    func deleteRepo(id: Int64) {
        store.deleteRepository(id: id)
        reloadAll()
        showToast("已删除软件源")
    }

    func updateRepo(_ repo: RepositoryItem) {
        store.updateRepository(repo)
        reloadAll()
    }

    // MARK: - GitHub Multi-Account & Reply Notifications

    func loginGitHubAccount(token: String) async throws {
        let acc = try await AccountSyncEngine.loginGitHubAccount(store: store, rawToken: token)
        reloadAll()
        let syncRes = await AccountSyncEngine.syncAccountNotifications(
            store: store,
            accountId: acc.id,
            onLocalNotify: { title, body, _ in
                Self.postLocalNotification(title: title, body: body)
            }
        )
        reloadAll()
        showToast("已登录 @\(acc.login)，同步到 \(syncRes.added) 条回复通知")
    }

    func syncAccountReplies(accountId: Int64? = nil, silent: Bool = false) async {
        guard !isSyncingAccounts else { return }
        isSyncingAccounts = true
        defer {
            isSyncingAccounts = false
            reloadAll()
        }
        if let aid = accountId {
            let res = await AccountSyncEngine.syncAccountNotifications(
                store: store,
                accountId: aid,
                onLocalNotify: { title, body, _ in
                    Self.postLocalNotification(title: title, body: body)
                }
            )
            if !silent {
                if let err = res.error {
                    showToast("同步失败：\(err)")
                } else {
                    showToast("已同步，新增 \(res.added) 条回复通知")
                }
            }
        } else {
            let added = await AccountSyncEngine.syncAllAccountsNotifications(
                store: store,
                onLocalNotify: { title, body, _ in
                    Self.postLocalNotification(title: title, body: body)
                }
            )
            lastAccountSyncAt = Date()
            if !silent {
                showToast("已同步全部账号，新增 \(added) 条回复通知")
            }
        }
    }

    func setDefaultGitHubAccount(id: Int64) {
        store.setDefaultGitHubAccount(id: id)
        if let acc = store.getGitHubAccount(id: id) {
            store.setSetting("github.token", value: acc.token)
        }
        reloadAll()
        showToast("已设为默认账号")
    }

    func toggleGitHubAccountEnabled(id: Int64, enabled: Bool) {
        store.setGitHubAccountEnabled(id: id, enabled: enabled)
        reloadAll()
    }

    func removeGitHubAccount(id: Int64) {
        store.deleteGitHubAccount(id: id)
        reloadAll()
        showToast("已退出账号")
    }

    func markAccountNotificationRead(id: Int64) {
        store.markAccountNotificationRead(id: id)
        reloadAll()
    }

    func markAllAccountNotificationsRead(accountId: Int64? = nil) {
        store.markAllAccountNotificationsRead(accountId: accountId)
        reloadAll()
    }

    // MARK: - Cloud Sync (WebDAV & GitHub Gist)

    func performCloudSync(direction: String = "auto", silent: Bool = false) async {
        guard !isCloudSyncing else { return }
        isCloudSyncing = true
        defer {
            isCloudSyncing = false
            reloadAll()
        }
        do {
            let res = try await CloudBackupEngine.runCloudSync(store: store, direction: direction)
            lastCloudSyncAt = Date()
            if !silent {
                showToast(res.summary)
            }
        } catch {
            if !silent {
                showToast("云同步失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Repo Syncing

    func syncRepo(id: Int64, trigger: String = "manual", full: Bool = false) async {
        guard !syncingRepoIds.contains(id) else { return }
        syncingRepoIds.insert(id)
        defer {
            syncingRepoIds.remove(id)
            reloadAll()
        }

        let (result, rl) = await SyncEngine.syncRepository(
            store: store,
            repoId: id,
            trigger: trigger,
            full: full,
            onLocalNotify: { title, body, _ in
                Self.postLocalNotification(title: title, body: body)
            }
        )
        if rl.remaining != nil || rl.limit != nil {
            rateLimit = rl
        }
        if trigger == "manual" {
            showToast(result.ok ? "同步完成：\(result.summary)" : "同步失败：\(result.summary)")
        }
    }

    func syncAll(onlyDue: Bool = false) async {
        guard !isSyncingAll else { return }
        let targets = store.listRepositories().filter { repo in
            guard !repo.paused else { return false }
            if !onlyDue { return true }
            guard let next = repo.nextSyncAt else { return true }
            return next <= Date()
        }
        guard !targets.isEmpty else {
            if !onlyDue { showToast("暂无可同步的软件源") }
            return
        }

        isSyncingAll = true
        defer {
            isSyncingAll = false
            syncProgressText = nil
            reloadAll()
        }

        let concurrency = max(1, min(6, store.getIntSetting("worker.concurrency", fallback: 2)))
        var okCount = 0
        var completed = 0
        var nextIndex = 0
        let total = targets.count
        let dbStore = store

        await withTaskGroup(of: (Int64, SyncResult, RateLimitInfo).self) { group in
            let initialBatch = min(concurrency, total)
            for _ in 0..<initialBatch {
                let repo = targets[nextIndex]
                nextIndex += 1
                syncingRepoIds.insert(repo.id)
                syncProgressText = "正在同步 (\(completed)/\(total)) \(repo.name)"
                group.addTask {
                    let (res, rl) = await SyncEngine.syncRepository(
                        store: dbStore,
                        repoId: repo.id,
                        trigger: onlyDue ? "schedule" : "batch",
                        full: false,
                        onLocalNotify: { title, body, _ in
                            Self.postLocalNotification(title: title, body: body)
                        }
                    )
                    return (repo.id, res, rl)
                }
            }

            for await (repoId, res, rl) in group {
                syncingRepoIds.remove(repoId)
                completed += 1
                if res.ok { okCount += 1 }
                if rl.remaining != nil || rl.limit != nil { rateLimit = rl }
                syncProgressText = "正在同步 (\(completed)/\(total))"
                reloadAll()

                if nextIndex < targets.count {
                    let repo = targets[nextIndex]
                    nextIndex += 1
                    syncingRepoIds.insert(repo.id)
                    syncProgressText = "正在同步 (\(completed)/\(total)) \(repo.name)"
                    group.addTask {
                        let (res, rl) = await SyncEngine.syncRepository(
                            store: dbStore,
                            repoId: repo.id,
                            trigger: onlyDue ? "schedule" : "batch",
                            full: false,
                            onLocalNotify: { title, body, _ in
                                Self.postLocalNotification(title: title, body: body)
                            }
                        )
                        return (repo.id, res, rl)
                    }
                }
            }
        }

        if !onlyDue {
            showToast("已完成同步 \(okCount)/\(total) 个软件源")
        }
    }

    private func startForegroundAutoPoll() {
        autoPollTask?.cancel()
        autoPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self = self, !Task.isCancelled else { break }
                if !self.isSyncingAll {
                    await self.syncAll(onlyDue: true)
                }
                // Sync GitHub account replies every 5 minutes
                if !self.githubAccounts.isEmpty && Date().timeIntervalSince(self.lastAccountSyncAt) >= 300 {
                    await self.syncAccountReplies(accountId: nil, silent: true)
                }
                // Auto cloud sync every 10 minutes if enabled
                if self.settings["cloud.autoSync"] == "true" && Date().timeIntervalSince(self.lastCloudSyncAt) >= 600 {
                    await self.performCloudSync(direction: "auto", silent: true)
                }
            }
        }
    }

    // MARK: - Multi-level Categories & Settings

    @discardableResult
    func createCategory(name: String, parentId: Int64? = nil) -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let newId = store.createCategory(name: trimmed, parentId: parentId)
        reloadAll()
        return newId
    }

    func updateCategory(id: Int64, name: String, parentId: Int64?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.updateCategory(id: id, name: trimmed, parentId: parentId)
        reloadAll()
    }

    func renameCategory(id: Int64, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.renameCategory(id: id, name: trimmed)
        reloadAll()
    }

    func deleteCategory(id: Int64) {
        store.deleteCategory(id: id)
        if selectedCategoryId == id { selectedCategoryId = nil }
        reloadAll()
    }

    func saveSetting(_ key: String, value: String) {
        store.setSetting(key, value: value)
        settings = store.getAllSettings()
    }

    func clearCache() {
        store.clearHttpCache()
        reloadAll()
        showToast("已清理 HTTP ETag 缓存")
    }

    func markNotificationsRead(ids: [Int64]) {
        store.markNotificationsRead(ids: ids)
        reloadAll()
    }

    func markAllNotificationsRead() {
        store.markAllNotificationsRead()
        store.markAllAccountNotificationsRead()
        reloadAll()
    }

    func clearNotifications() {
        store.clearNotifications()
        reloadAll()
    }

    // MARK: - Local iOS Notifications

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    nonisolated static func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
