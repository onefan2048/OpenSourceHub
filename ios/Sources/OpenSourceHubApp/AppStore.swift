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
    @Published var stats: HubStats = .empty
    @Published var settings: [String: String] = HubSettings.defaults
    @Published var rateLimit: RateLimitInfo = RateLimitInfo()

    @Published var syncingRepoIds: Set<Int64> = []
    @Published var isSyncingAll: Bool = false
    @Published var syncProgressText: String?
    @Published var toastMessage: String?

    @Published var selectedTab: Int = 0
    @Published var selectedCategoryId: Int64? = nil // nil = all, -1 = uncategorized

    private var autoPollTask: Task<Void, Never>?

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
        stats = store.getStats()
        settings = store.getAllSettings()
    }

    func categoryPath(for categoryId: Int64?) -> String? {
        guard let cid = categoryId else { return nil }
        return categoryTree.first(where: { $0.id == cid })?.path
    }

    func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
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

    // MARK: - Syncing

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
