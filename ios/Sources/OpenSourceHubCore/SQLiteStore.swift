import Foundation
import SQLite3

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteStore: @unchecked Sendable {
    public let dbPath: String
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.opensourcehub.sqlite", qos: .userInitiated)

    public init(path: String) throws {
        self.dbPath = path
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty && dir != ":memory:" {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open failed"
            if let h = handle { sqlite3_close(h) }
            throw NSError(domain: "SQLiteStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        self.db = h
        try queue.sync {
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA foreign_keys=ON;")
            try exec("PRAGMA busy_timeout=5000;")
            try migrate()
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Schema

    private func migrate() throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            parent_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS repositories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT NOT NULL DEFAULT 'github',
            provider_repo_id TEXT,
            owner TEXT NOT NULL,
            name TEXT NOT NULL,
            full_name TEXT NOT NULL,
            full_name_key TEXT NOT NULL,
            description TEXT,
            homepage TEXT,
            html_url TEXT NOT NULL,
            avatar_url TEXT,
            logo_url TEXT,
            stars INTEGER NOT NULL DEFAULT 0,
            forks INTEGER NOT NULL DEFAULT 0,
            watchers INTEGER NOT NULL DEFAULT 0,
            license TEXT,
            language TEXT,
            topics TEXT NOT NULL DEFAULT '[]',
            default_branch TEXT,
            is_archived INTEGER NOT NULL DEFAULT 0,
            is_fork INTEGER NOT NULL DEFAULT 0,
            pushed_at REAL,
            has_releases INTEGER NOT NULL DEFAULT 0,
            has_tags INTEGER NOT NULL DEFAULT 0,
            has_assets INTEGER NOT NULL DEFAULT 0,
            platforms TEXT NOT NULL DEFAULT '[]',
            file_types TEXT NOT NULL DEFAULT '[]',
            status TEXT NOT NULL DEFAULT 'pending',
            accessible INTEGER NOT NULL DEFAULT 1,
            last_error TEXT,
            head_sha TEXT,
            latest_version TEXT,
            latest_version_source TEXT,
            latest_version_at REAL,
            latest_activity_at REAL,
            readme TEXT,
            readme_sha TEXT,
            watched_files TEXT NOT NULL DEFAULT '[]',
            poll_interval_minutes INTEGER,
            paused INTEGER NOT NULL DEFAULT 0,
            baseline_established INTEGER NOT NULL DEFAULT 0,
            baseline_at REAL,
            notify_enabled INTEGER NOT NULL DEFAULT 1,
            notify_release INTEGER NOT NULL DEFAULT 1,
            notify_prerelease INTEGER NOT NULL DEFAULT 0,
            notify_tag INTEGER NOT NULL DEFAULT 0,
            notify_commit INTEGER NOT NULL DEFAULT 0,
            notify_changelog INTEGER NOT NULL DEFAULT 0,
            last_synced_at REAL,
            last_sync_status TEXT,
            last_sync_duration_ms INTEGER,
            next_sync_at REAL,
            consecutive_failures INTEGER NOT NULL DEFAULT 0,
            category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
            added_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(provider, full_name_key)
        );
        CREATE INDEX IF NOT EXISTS idx_repos_category ON repositories(category_id);

        CREATE TABLE IF NOT EXISTS releases (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
            provider_id TEXT NOT NULL,
            tag_name TEXT NOT NULL,
            name TEXT,
            body TEXT,
            is_prerelease INTEGER NOT NULL DEFAULT 0,
            is_draft INTEGER NOT NULL DEFAULT 0,
            is_latest INTEGER NOT NULL DEFAULT 0,
            published_at REAL,
            html_url TEXT NOT NULL,
            zipball_url TEXT,
            tarball_url TEXT,
            author_login TEXT,
            asset_count INTEGER NOT NULL DEFAULT 0,
            UNIQUE(repository_id, provider_id)
        );
        CREATE INDEX IF NOT EXISTS idx_releases_repo ON releases(repository_id, published_at);

        CREATE TABLE IF NOT EXISTS assets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
            release_id INTEGER NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
            provider_id TEXT NOT NULL,
            name TEXT NOT NULL,
            label TEXT,
            content_type TEXT,
            size INTEGER NOT NULL DEFAULT 0,
            download_count INTEGER NOT NULL DEFAULT 0,
            download_url TEXT NOT NULL,
            sha256 TEXT,
            platform TEXT NOT NULL,
            arch TEXT NOT NULL,
            file_type TEXT NOT NULL,
            kind TEXT NOT NULL,
            confidence TEXT NOT NULL,
            created_at_remote REAL,
            UNIQUE(release_id, provider_id)
        );
        CREATE INDEX IF NOT EXISTS idx_assets_repo_plat ON assets(repository_id, platform);

        CREATE TABLE IF NOT EXISTS tags (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            commit_sha TEXT NOT NULL,
            commit_date REAL,
            zipball_url TEXT,
            tarball_url TEXT,
            UNIQUE(repository_id, name)
        );

        CREATE TABLE IF NOT EXISTS commits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
            sha TEXT NOT NULL,
            short_sha TEXT NOT NULL,
            message TEXT NOT NULL,
            author_name TEXT,
            author_login TEXT,
            committed_at REAL,
            html_url TEXT NOT NULL,
            branch TEXT,
            UNIQUE(repository_id, sha)
        );
        CREATE INDEX IF NOT EXISTS idx_commits_repo ON commits(repository_id, committed_at);

        CREATE TABLE IF NOT EXISTS tracked_files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            kind TEXT NOT NULL,
            last_sha TEXT,
            last_version TEXT,
            last_checked_at REAL,
            last_changed_at REAL,
            UNIQUE(repository_id, path)
        );

        CREATE TABLE IF NOT EXISTS changelog_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
            file_path TEXT NOT NULL,
            version TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT,
            entry_date TEXT,
            UNIQUE(repository_id, file_path, version)
        );

        CREATE TABLE IF NOT EXISTS version_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
            source_type TEXT NOT NULL,
            event_type TEXT NOT NULL,
            source_key TEXT NOT NULL,
            version TEXT,
            title TEXT NOT NULL,
            url TEXT,
            occurred_at REAL,
            is_baseline INTEGER NOT NULL DEFAULT 0,
            detected_at REAL NOT NULL,
            UNIQUE(repository_id, source_type, source_key)
        );

        CREATE TABLE IF NOT EXISTS sync_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
            trigger TEXT NOT NULL,
            mode TEXT NOT NULL,
            status TEXT NOT NULL,
            started_at REAL NOT NULL,
            finished_at REAL,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            request_count INTEGER NOT NULL DEFAULT 0,
            not_modified_count INTEGER NOT NULL DEFAULT 0,
            new_releases INTEGER NOT NULL DEFAULT 0,
            new_tags INTEGER NOT NULL DEFAULT 0,
            new_commits INTEGER NOT NULL DEFAULT 0,
            new_assets INTEGER NOT NULL DEFAULT 0,
            new_changelog INTEGER NOT NULL DEFAULT 0,
            summary TEXT,
            error TEXT,
            rate_limit_remaining INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_synclogs_repo ON sync_logs(repository_id, started_at);

        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS notifications (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
            version_event_id INTEGER REFERENCES version_events(id) ON DELETE SET NULL,
            channel TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT,
            url TEXT,
            status TEXT NOT NULL DEFAULT 'sent',
            error TEXT,
            read_at REAL,
            created_at REAL NOT NULL,
            UNIQUE(version_event_id, channel)
        );
        CREATE INDEX IF NOT EXISTS idx_notifications_created ON notifications(created_at);

        CREATE TABLE IF NOT EXISTS http_cache (
            key TEXT PRIMARY KEY,
            etag TEXT,
            last_modified TEXT,
            body TEXT NOT NULL,
            link_header TEXT,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS issues (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
            number INTEGER NOT NULL,
            title TEXT NOT NULL,
            state TEXT NOT NULL,
            author_login TEXT,
            labels TEXT NOT NULL DEFAULT '[]',
            comments INTEGER NOT NULL DEFAULT 0,
            html_url TEXT NOT NULL,
            body TEXT,
            created_at_remote REAL NOT NULL,
            updated_at_remote REAL NOT NULL,
            UNIQUE(repository_id, number)
        );

        CREATE TABLE IF NOT EXISTS discussions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
            number INTEGER NOT NULL,
            title TEXT NOT NULL,
            author_login TEXT,
            category_name TEXT,
            category_emoji TEXT,
            is_answered INTEGER NOT NULL DEFAULT 0,
            closed INTEGER NOT NULL DEFAULT 0,
            upvotes INTEGER NOT NULL DEFAULT 0,
            comments INTEGER NOT NULL DEFAULT 0,
            html_url TEXT NOT NULL,
            body TEXT,
            created_at_remote REAL NOT NULL,
            updated_at_remote REAL NOT NULL,
            UNIQUE(repository_id, number)
        );
        """
        try exec(schema)
        // Safe v2 column migrations for existing v1 databases
        _ = try? exec("ALTER TABLE repositories ADD COLUMN languages_json TEXT NOT NULL DEFAULT '{}';")
        _ = try? exec("ALTER TABLE repositories ADD COLUMN root_tree_json TEXT NOT NULL DEFAULT '[]';")
    }

    private func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            sqlite3_free(errMsg)
            throw NSError(domain: "SQLiteStore", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // MARK: - Binding & Reading Helpers

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ val: String?) {
        if let v = val {
            sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_PTR)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindInt(_ stmt: OpaquePointer?, _ idx: Int32, _ val: Int?) {
        if let v = val { sqlite3_bind_int64(stmt, idx, Int64(v)) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func bindInt64(_ stmt: OpaquePointer?, _ idx: Int32, _ val: Int64?) {
        if let v = val { sqlite3_bind_int64(stmt, idx, v) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func bindDate(_ stmt: OpaquePointer?, _ idx: Int32, _ val: Date?) {
        if let v = val { sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL, let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private func colInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, idx))
    }

    private func colInt64(_ stmt: OpaquePointer?, _ idx: Int32) -> Int64? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, idx)
    }

    private func colDate(_ stmt: OpaquePointer?, _ idx: Int32) -> Date? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, idx))
    }

    private func colBool(_ stmt: OpaquePointer?, _ idx: Int32) -> Bool {
        sqlite3_column_int(stmt, idx) != 0
    }

    private func decodeStringArray(_ json: String?) -> [String] {
        guard let json = json, let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    private func encodeStringArray(_ arr: [String]) -> String {
        guard let data = try? JSONEncoder().encode(arr), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    // MARK: - Settings

    public func getAllSettings() -> [String: String] {
        queue.sync {
            var out = HubSettings.defaults
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT key, value FROM settings;", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let k = colText(stmt, 0), let v = colText(stmt, 1) {
                        out[k] = v
                    }
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    public func getSetting(_ key: String) -> String {
        getAllSettings()[key] ?? HubSettings.defaults[key] ?? ""
    }

    public func getIntSetting(_ key: String, fallback: Int) -> Int {
        Int(getSetting(key)) ?? fallback
    }

    public func setSetting(_ key: String, value: String) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO settings(key, value, updated_at) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, 1, key)
                bindText(stmt, 2, value)
                bindDate(stmt, 3, Date())
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Categories

    public func listCategories() -> [CategoryItem] {
        queue.sync {
            var items: [CategoryItem] = []
            let sql = """
            SELECT c.id, c.name, c.parent_id, c.sort_order,
                   (SELECT COUNT(*) FROM repositories r WHERE r.category_id = c.id) AS repo_cnt
            FROM categories c
            ORDER BY c.sort_order ASC, c.id ASC;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    items.append(CategoryItem(
                        id: sqlite3_column_int64(stmt, 0),
                        name: colText(stmt, 1) ?? "",
                        parentId: colInt64(stmt, 2),
                        sortOrder: Int(sqlite3_column_int64(stmt, 3)),
                        repoCount: Int(sqlite3_column_int64(stmt, 4))
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return items
        }
    }

    @discardableResult
    public func createCategory(name: String, parentId: Int64? = nil) -> Int64 {
        queue.sync {
            let now = Date()
            var stmt: OpaquePointer?
            let sql = "INSERT INTO categories(name, parent_id, sort_order, created_at, updated_at) VALUES(?,?,0,?,?);"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, 1, name.trimmingCharacters(in: .whitespacesAndNewlines))
                bindInt64(stmt, 2, parentId)
                bindDate(stmt, 3, now)
                bindDate(stmt, 4, now)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func updateCategory(id: Int64, name: String, parentId: Int64?) {
        queue.sync {
            let safeParent = (parentId == id) ? nil : parentId
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE categories SET name=?, parent_id=?, updated_at=? WHERE id=?;", -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, 1, name.trimmingCharacters(in: .whitespacesAndNewlines))
                bindInt64(stmt, 2, safeParent)
                bindDate(stmt, 3, Date())
                bindInt64(stmt, 4, id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func renameCategory(id: Int64, name: String) {
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE categories SET name=?, updated_at=? WHERE id=?;", -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, 1, name.trimmingCharacters(in: .whitespacesAndNewlines))
                bindDate(stmt, 2, Date())
                bindInt64(stmt, 3, id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func deleteCategory(id: Int64) {
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM categories WHERE id=?;", -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Repositories

    private static let repoSelectColumns = """
        id, provider, provider_repo_id, owner, name, full_name, full_name_key, description, homepage, html_url,
        avatar_url, logo_url, stars, forks, watchers, license, language, topics, default_branch, is_archived,
        is_fork, pushed_at, has_releases, has_tags, has_assets, platforms, file_types, status, accessible,
        last_error, head_sha, latest_version, latest_version_source, latest_version_at, latest_activity_at,
        readme, readme_sha, watched_files, poll_interval_minutes, paused, baseline_established, baseline_at,
        notify_enabled, notify_release, notify_prerelease, notify_tag, notify_commit, notify_changelog,
        last_synced_at, last_sync_status, last_sync_duration_ms, next_sync_at, consecutive_failures,
        category_id, added_at, updated_at, languages_json, root_tree_json
    """

    private func decodeLanguages(_ json: String?) -> [String: Int] {
        guard let json = json, let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return dict
    }

    private func encodeLanguages(_ dict: [String: Int]) -> String {
        guard let data = try? JSONEncoder().encode(dict), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func decodeRootTree(_ json: String?) -> [RepoTreeEntry] {
        guard let json = json, let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([RepoTreeEntry].self, from: data) else { return [] }
        return arr
    }

    private func encodeRootTree(_ arr: [RepoTreeEntry]) -> String {
        guard let data = try? JSONEncoder().encode(arr), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private func readRepo(_ stmt: OpaquePointer?) -> RepositoryItem {
        RepositoryItem(
            id: sqlite3_column_int64(stmt, 0),
            provider: colText(stmt, 1) ?? "github",
            providerRepoId: colText(stmt, 2),
            owner: colText(stmt, 3) ?? "",
            name: colText(stmt, 4) ?? "",
            fullName: colText(stmt, 5) ?? "",
            fullNameKey: colText(stmt, 6) ?? "",
            description: colText(stmt, 7),
            homepage: colText(stmt, 8),
            htmlUrl: colText(stmt, 9) ?? "",
            avatarUrl: colText(stmt, 10),
            logoUrl: colText(stmt, 11),
            stars: Int(sqlite3_column_int64(stmt, 12)),
            forks: Int(sqlite3_column_int64(stmt, 13)),
            watchers: Int(sqlite3_column_int64(stmt, 14)),
            license: colText(stmt, 15),
            language: colText(stmt, 16),
            languages: decodeLanguages(colText(stmt, 56)),
            rootTree: decodeRootTree(colText(stmt, 57)),
            topics: decodeStringArray(colText(stmt, 17)),
            defaultBranch: colText(stmt, 18),
            isArchived: colBool(stmt, 19),
            isFork: colBool(stmt, 20),
            pushedAt: colDate(stmt, 21),
            hasReleases: colBool(stmt, 22),
            hasTags: colBool(stmt, 23),
            hasAssets: colBool(stmt, 24),
            platforms: decodeStringArray(colText(stmt, 25)),
            fileTypes: decodeStringArray(colText(stmt, 26)),
            status: colText(stmt, 27) ?? "pending",
            accessible: colBool(stmt, 28),
            lastError: colText(stmt, 29),
            headSha: colText(stmt, 30),
            latestVersion: colText(stmt, 31),
            latestVersionSource: colText(stmt, 32),
            latestVersionAt: colDate(stmt, 33),
            latestActivityAt: colDate(stmt, 34),
            readme: colText(stmt, 35),
            readmeSha: colText(stmt, 36),
            watchedFiles: decodeStringArray(colText(stmt, 37)),
            pollIntervalMinutes: colInt(stmt, 38),
            paused: colBool(stmt, 39),
            baselineEstablished: colBool(stmt, 40),
            baselineAt: colDate(stmt, 41),
            notifyEnabled: colBool(stmt, 42),
            notifyRelease: colBool(stmt, 43),
            notifyPrerelease: colBool(stmt, 44),
            notifyTag: colBool(stmt, 45),
            notifyCommit: colBool(stmt, 46),
            notifyChangelog: colBool(stmt, 47),
            lastSyncedAt: colDate(stmt, 48),
            lastSyncStatus: colText(stmt, 49),
            lastSyncDurationMs: colInt(stmt, 50),
            nextSyncAt: colDate(stmt, 51),
            consecutiveFailures: Int(sqlite3_column_int64(stmt, 52)),
            categoryId: colInt64(stmt, 53),
            addedAt: colDate(stmt, 54) ?? Date(),
            updatedAt: colDate(stmt, 55) ?? Date()
        )
    }

    public func listRepositories() -> [RepositoryItem] {
        queue.sync {
            var out: [RepositoryItem] = []
            let sql = "SELECT \(Self.repoSelectColumns) FROM repositories ORDER BY COALESCE(latest_activity_at, added_at) DESC, id DESC;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out.append(readRepo(stmt))
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    public func getRepository(id: Int64) -> RepositoryItem? {
        queue.sync {
            let sql = "SELECT \(Self.repoSelectColumns) FROM repositories WHERE id=?;"
            var stmt: OpaquePointer?
            var item: RepositoryItem?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, id)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    item = readRepo(stmt)
                }
            }
            sqlite3_finalize(stmt)
            return item
        }
    }

    public func findRepository(fullNameKey: String) -> RepositoryItem? {
        queue.sync {
            let sql = "SELECT \(Self.repoSelectColumns) FROM repositories WHERE provider='github' AND full_name_key=?;"
            var stmt: OpaquePointer?
            var item: RepositoryItem?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, 1, fullNameKey.lowercased())
                if sqlite3_step(stmt) == SQLITE_ROW {
                    item = readRepo(stmt)
                }
            }
            sqlite3_finalize(stmt)
            return item
        }
    }

    public func addRepository(_ ref: RepoRef, categoryId: Int64? = nil) -> (repo: RepositoryItem, created: Bool)? {
        if let existing = findRepository(fullNameKey: ref.fullNameKey) {
            return (existing, false)
        }
        let id: Int64 = queue.sync {
            let now = Date()
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO repositories(provider, owner, name, full_name, full_name_key, html_url, category_id, added_at, updated_at)
            VALUES('github',?,?,?,?,?,?,?,?);
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, 1, ref.owner)
                bindText(stmt, 2, ref.name)
                bindText(stmt, 3, ref.fullName)
                bindText(stmt, 4, ref.fullNameKey)
                bindText(stmt, 5, ref.htmlUrl)
                bindInt64(stmt, 6, categoryId)
                bindDate(stmt, 7, now)
                bindDate(stmt, 8, now)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return sqlite3_last_insert_rowid(db)
        }
        guard let created = getRepository(id: id) else { return nil }
        return (created, true)
    }

    public func updateRepository(_ repo: RepositoryItem) {
        queue.sync {
            let sql = """
            UPDATE repositories SET
                provider_repo_id=?, owner=?, name=?, full_name=?, full_name_key=?, description=?, homepage=?, html_url=?,
                avatar_url=?, logo_url=?, stars=?, forks=?, watchers=?, license=?, language=?, topics=?, default_branch=?,
                is_archived=?, is_fork=?, pushed_at=?, has_releases=?, has_tags=?, has_assets=?, platforms=?, file_types=?,
                status=?, accessible=?, last_error=?, head_sha=?, latest_version=?, latest_version_source=?,
                latest_version_at=?, latest_activity_at=?, readme=?, readme_sha=?, watched_files=?, poll_interval_minutes=?,
                paused=?, baseline_established=?, baseline_at=?, notify_enabled=?, notify_release=?, notify_prerelease=?,
                notify_tag=?, notify_commit=?, notify_changelog=?, last_synced_at=?, last_sync_status=?,
                last_sync_duration_ms=?, next_sync_at=?, consecutive_failures=?, category_id=?, updated_at=?,
                languages_json=?, root_tree_json=?
            WHERE id=?;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, 1, repo.providerRepoId)
                bindText(stmt, 2, repo.owner)
                bindText(stmt, 3, repo.name)
                bindText(stmt, 4, repo.fullName)
                bindText(stmt, 5, repo.fullNameKey)
                bindText(stmt, 6, repo.description)
                bindText(stmt, 7, repo.homepage)
                bindText(stmt, 8, repo.htmlUrl)
                bindText(stmt, 9, repo.avatarUrl)
                bindText(stmt, 10, repo.logoUrl)
                bindInt(stmt, 11, repo.stars)
                bindInt(stmt, 12, repo.forks)
                bindInt(stmt, 13, repo.watchers)
                bindText(stmt, 14, repo.license)
                bindText(stmt, 15, repo.language)
                bindText(stmt, 16, encodeStringArray(repo.topics))
                bindText(stmt, 17, repo.defaultBranch)
                sqlite3_bind_int(stmt, 18, repo.isArchived ? 1 : 0)
                sqlite3_bind_int(stmt, 19, repo.isFork ? 1 : 0)
                bindDate(stmt, 20, repo.pushedAt)
                sqlite3_bind_int(stmt, 21, repo.hasReleases ? 1 : 0)
                sqlite3_bind_int(stmt, 22, repo.hasTags ? 1 : 0)
                sqlite3_bind_int(stmt, 23, repo.hasAssets ? 1 : 0)
                bindText(stmt, 24, encodeStringArray(repo.platforms))
                bindText(stmt, 25, encodeStringArray(repo.fileTypes))
                bindText(stmt, 26, repo.status)
                sqlite3_bind_int(stmt, 27, repo.accessible ? 1 : 0)
                bindText(stmt, 28, repo.lastError)
                bindText(stmt, 29, repo.headSha)
                bindText(stmt, 30, repo.latestVersion)
                bindText(stmt, 31, repo.latestVersionSource)
                bindDate(stmt, 32, repo.latestVersionAt)
                bindDate(stmt, 33, repo.latestActivityAt)
                bindText(stmt, 34, repo.readme)
                bindText(stmt, 35, repo.readmeSha)
                bindText(stmt, 36, encodeStringArray(repo.watchedFiles))
                bindInt(stmt, 37, repo.pollIntervalMinutes)
                sqlite3_bind_int(stmt, 38, repo.paused ? 1 : 0)
                sqlite3_bind_int(stmt, 39, repo.baselineEstablished ? 1 : 0)
                bindDate(stmt, 40, repo.baselineAt)
                sqlite3_bind_int(stmt, 41, repo.notifyEnabled ? 1 : 0)
                sqlite3_bind_int(stmt, 42, repo.notifyRelease ? 1 : 0)
                sqlite3_bind_int(stmt, 43, repo.notifyPrerelease ? 1 : 0)
                sqlite3_bind_int(stmt, 44, repo.notifyTag ? 1 : 0)
                sqlite3_bind_int(stmt, 45, repo.notifyCommit ? 1 : 0)
                sqlite3_bind_int(stmt, 46, repo.notifyChangelog ? 1 : 0)
                bindDate(stmt, 47, repo.lastSyncedAt)
                bindText(stmt, 48, repo.lastSyncStatus)
                bindInt(stmt, 49, repo.lastSyncDurationMs)
                bindDate(stmt, 50, repo.nextSyncAt)
                bindInt(stmt, 51, repo.consecutiveFailures)
                bindInt64(stmt, 52, repo.categoryId)
                bindDate(stmt, 53, Date())
                bindText(stmt, 54, encodeLanguages(repo.languages))
                bindText(stmt, 55, encodeRootTree(repo.rootTree))
                bindInt64(stmt, 56, repo.id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func deleteRepository(id: Int64) {
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM repositories WHERE id=?;", -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Releases & Assets

    public func upsertRelease(_ r: ReleaseItem) -> (id: Int64, inserted: Bool) {
        queue.sync {
            var existingId: Int64?
            var check: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id FROM releases WHERE repository_id=? AND provider_id=?;", -1, &check, nil) == SQLITE_OK {
                bindInt64(check, 1, r.repositoryId)
                bindText(check, 2, r.providerId)
                if sqlite3_step(check) == SQLITE_ROW { existingId = sqlite3_column_int64(check, 0) }
            }
            sqlite3_finalize(check)

            if let id = existingId {
                var stmt: OpaquePointer?
                let sql = """
                UPDATE releases SET tag_name=?, name=?, body=?, is_prerelease=?, is_draft=?, is_latest=?,
                    published_at=?, html_url=?, zipball_url=?, tarball_url=?, author_login=?, asset_count=?
                WHERE id=?;
                """
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    bindText(stmt, 1, r.tagName)
                    bindText(stmt, 2, r.name)
                    bindText(stmt, 3, r.body)
                    sqlite3_bind_int(stmt, 4, r.isPrerelease ? 1 : 0)
                    sqlite3_bind_int(stmt, 5, r.isDraft ? 1 : 0)
                    sqlite3_bind_int(stmt, 6, r.isLatest ? 1 : 0)
                    bindDate(stmt, 7, r.publishedAt)
                    bindText(stmt, 8, r.htmlUrl)
                    bindText(stmt, 9, r.zipballUrl)
                    bindText(stmt, 10, r.tarballUrl)
                    bindText(stmt, 11, r.authorLogin)
                    bindInt(stmt, 12, r.assetCount)
                    bindInt64(stmt, 13, id)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
                return (id, false)
            } else {
                var stmt: OpaquePointer?
                let sql = """
                INSERT INTO releases(repository_id, provider_id, tag_name, name, body, is_prerelease, is_draft, is_latest,
                    published_at, html_url, zipball_url, tarball_url, author_login, asset_count)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    bindInt64(stmt, 1, r.repositoryId)
                    bindText(stmt, 2, r.providerId)
                    bindText(stmt, 3, r.tagName)
                    bindText(stmt, 4, r.name)
                    bindText(stmt, 5, r.body)
                    sqlite3_bind_int(stmt, 6, r.isPrerelease ? 1 : 0)
                    sqlite3_bind_int(stmt, 7, r.isDraft ? 1 : 0)
                    sqlite3_bind_int(stmt, 8, r.isLatest ? 1 : 0)
                    bindDate(stmt, 9, r.publishedAt)
                    bindText(stmt, 10, r.htmlUrl)
                    bindText(stmt, 11, r.zipballUrl)
                    bindText(stmt, 12, r.tarballUrl)
                    bindText(stmt, 13, r.authorLogin)
                    bindInt(stmt, 14, r.assetCount)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
                return (sqlite3_last_insert_rowid(db), true)
            }
        }
    }

    public func listReleases(repositoryId: Int64) -> [ReleaseItem] {
        queue.sync {
            var out: [ReleaseItem] = []
            let sql = """
            SELECT id, repository_id, provider_id, tag_name, name, body, is_prerelease, is_draft, is_latest,
                   published_at, html_url, zipball_url, tarball_url, author_login, asset_count
            FROM releases WHERE repository_id=? ORDER BY COALESCE(published_at, 0) DESC, id DESC;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, repositoryId)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out.append(ReleaseItem(
                        id: sqlite3_column_int64(stmt, 0),
                        repositoryId: sqlite3_column_int64(stmt, 1),
                        providerId: colText(stmt, 2) ?? "",
                        tagName: colText(stmt, 3) ?? "",
                        name: colText(stmt, 4),
                        body: colText(stmt, 5),
                        isPrerelease: colBool(stmt, 6),
                        isDraft: colBool(stmt, 7),
                        isLatest: colBool(stmt, 8),
                        publishedAt: colDate(stmt, 9),
                        htmlUrl: colText(stmt, 10) ?? "",
                        zipballUrl: colText(stmt, 11),
                        tarballUrl: colText(stmt, 12),
                        authorLogin: colText(stmt, 13),
                        assetCount: Int(sqlite3_column_int64(stmt, 14))
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    public func upsertAsset(_ a: AssetItem) -> Bool {
        queue.sync {
            var exists = false
            var check: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id FROM assets WHERE release_id=? AND provider_id=?;", -1, &check, nil) == SQLITE_OK {
                bindInt64(check, 1, a.releaseId)
                bindText(check, 2, a.providerId)
                exists = sqlite3_step(check) == SQLITE_ROW
            }
            sqlite3_finalize(check)

            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO assets(repository_id, release_id, provider_id, name, label, content_type, size, download_count,
                download_url, sha256, platform, arch, file_type, kind, confidence, created_at_remote)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(release_id, provider_id) DO UPDATE SET
                name=excluded.name, label=excluded.label, content_type=excluded.content_type, size=excluded.size,
                download_count=excluded.download_count, download_url=excluded.download_url, sha256=excluded.sha256,
                platform=excluded.platform, arch=excluded.arch, file_type=excluded.file_type, kind=excluded.kind,
                confidence=excluded.confidence;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, a.repositoryId)
                bindInt64(stmt, 2, a.releaseId)
                bindText(stmt, 3, a.providerId)
                bindText(stmt, 4, a.name)
                bindText(stmt, 5, a.label)
                bindText(stmt, 6, a.contentType)
                bindInt64(stmt, 7, a.size)
                bindInt(stmt, 8, a.downloadCount)
                bindText(stmt, 9, a.downloadUrl)
                bindText(stmt, 10, a.sha256)
                bindText(stmt, 11, a.platform)
                bindText(stmt, 12, a.arch)
                bindText(stmt, 13, a.fileType)
                bindText(stmt, 14, a.kind)
                bindText(stmt, 15, a.confidence)
                bindDate(stmt, 16, a.createdAtRemote)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return !exists
        }
    }

    public func listAssets(repositoryId: Int64? = nil, platform: String? = nil, softwareOnly: Bool = false, limit: Int = 500) -> [AssetItem] {
        queue.sync {
            var out: [AssetItem] = []
            var clauses: [String] = []
            if repositoryId != nil { clauses.append("a.repository_id = ?") }
            if let p = platform, !p.isEmpty { clauses.append("a.platform = ?") }
            if softwareOnly { clauses.append("a.kind IN ('installer','package','archive','binary')") }
            let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sql = """
            SELECT a.id, a.repository_id, a.release_id, a.provider_id, a.name, a.label, a.content_type, a.size,
                   a.download_count, a.download_url, a.sha256, a.platform, a.arch, a.file_type, a.kind, a.confidence,
                   a.created_at_remote, r.full_name, rel.tag_name
            FROM assets a
            JOIN repositories r ON r.id = a.repository_id
            JOIN releases rel ON rel.id = a.release_id
            \(whereClause)
            ORDER BY COALESCE(rel.published_at, a.created_at_remote, 0) DESC, a.id DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                var idx: Int32 = 1
                if let rid = repositoryId { bindInt64(stmt, idx, rid); idx += 1 }
                if let p = platform, !p.isEmpty { bindText(stmt, idx, p); idx += 1 }
                bindInt(stmt, idx, limit)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out.append(AssetItem(
                        id: sqlite3_column_int64(stmt, 0),
                        repositoryId: sqlite3_column_int64(stmt, 1),
                        releaseId: sqlite3_column_int64(stmt, 2),
                        providerId: colText(stmt, 3) ?? "",
                        name: colText(stmt, 4) ?? "",
                        label: colText(stmt, 5),
                        contentType: colText(stmt, 6),
                        size: sqlite3_column_int64(stmt, 7),
                        downloadCount: Int(sqlite3_column_int64(stmt, 8)),
                        downloadUrl: colText(stmt, 9) ?? "",
                        sha256: colText(stmt, 10),
                        platform: colText(stmt, 11) ?? "unknown",
                        arch: colText(stmt, 12) ?? "unknown",
                        fileType: colText(stmt, 13) ?? "binary",
                        kind: colText(stmt, 14) ?? "other",
                        confidence: colText(stmt, 15) ?? "low",
                        createdAtRemote: colDate(stmt, 16),
                        repoFullName: colText(stmt, 17),
                        releaseTag: colText(stmt, 18)
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    // MARK: - Tags & Commits

    public func upsertTag(_ t: TagItem) -> Bool {
        queue.sync {
            var exists = false
            var check: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id FROM tags WHERE repository_id=? AND name=?;", -1, &check, nil) == SQLITE_OK {
                bindInt64(check, 1, t.repositoryId)
                bindText(check, 2, t.name)
                exists = sqlite3_step(check) == SQLITE_ROW
            }
            sqlite3_finalize(check)

            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO tags(repository_id, name, commit_sha, commit_date, zipball_url, tarball_url)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(repository_id, name) DO UPDATE SET
                commit_sha=excluded.commit_sha,
                commit_date=COALESCE(excluded.commit_date, tags.commit_date),
                zipball_url=excluded.zipball_url,
                tarball_url=excluded.tarball_url;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, t.repositoryId)
                bindText(stmt, 2, t.name)
                bindText(stmt, 3, t.commitSha)
                bindDate(stmt, 4, t.commitDate)
                bindText(stmt, 5, t.zipballUrl)
                bindText(stmt, 6, t.tarballUrl)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return !exists
        }
    }

    public func listTags(repositoryId: Int64) -> [TagItem] {
        queue.sync {
            var out: [TagItem] = []
            var stmt: OpaquePointer?
            let sql = "SELECT id, repository_id, name, commit_sha, commit_date, zipball_url, tarball_url FROM tags WHERE repository_id=? ORDER BY COALESCE(commit_date, 0) DESC, id DESC;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, repositoryId)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out.append(TagItem(
                        id: sqlite3_column_int64(stmt, 0),
                        repositoryId: sqlite3_column_int64(stmt, 1),
                        name: colText(stmt, 2) ?? "",
                        commitSha: colText(stmt, 3) ?? "",
                        commitDate: colDate(stmt, 4),
                        zipballUrl: colText(stmt, 5),
                        tarballUrl: colText(stmt, 6)
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    public func upsertCommit(_ c: CommitItem) -> Bool {
        queue.sync {
            var exists = false
            var check: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id FROM commits WHERE repository_id=? AND sha=?;", -1, &check, nil) == SQLITE_OK {
                bindInt64(check, 1, c.repositoryId)
                bindText(check, 2, c.sha)
                exists = sqlite3_step(check) == SQLITE_ROW
            }
            sqlite3_finalize(check)
            if exists { return false }

            var stmt: OpaquePointer?
            let sql = "INSERT OR IGNORE INTO commits(repository_id, sha, short_sha, message, author_name, author_login, committed_at, html_url, branch) VALUES(?,?,?,?,?,?,?,?,?);"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, c.repositoryId)
                bindText(stmt, 2, c.sha)
                bindText(stmt, 3, c.shortSha)
                bindText(stmt, 4, c.message)
                bindText(stmt, 5, c.authorName)
                bindText(stmt, 6, c.authorLogin)
                bindDate(stmt, 7, c.committedAt)
                bindText(stmt, 8, c.htmlUrl)
                bindText(stmt, 9, c.branch)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return true
        }
    }

    public func listCommits(repositoryId: Int64, limit: Int = 100) -> [CommitItem] {
        queue.sync {
            var out: [CommitItem] = []
            var stmt: OpaquePointer?
            let sql = "SELECT id, repository_id, sha, short_sha, message, author_name, author_login, committed_at, html_url, branch FROM commits WHERE repository_id=? ORDER BY COALESCE(committed_at, 0) DESC, id DESC LIMIT ?;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, repositoryId)
                bindInt(stmt, 2, limit)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out.append(CommitItem(
                        id: sqlite3_column_int64(stmt, 0),
                        repositoryId: sqlite3_column_int64(stmt, 1),
                        sha: colText(stmt, 2) ?? "",
                        shortSha: colText(stmt, 3) ?? "",
                        message: colText(stmt, 4) ?? "",
                        authorName: colText(stmt, 5),
                        authorLogin: colText(stmt, 6),
                        committedAt: colDate(stmt, 7),
                        htmlUrl: colText(stmt, 8) ?? "",
                        branch: colText(stmt, 9)
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    // MARK: - Changelog & Tracked Files

    public func upsertChangelogEntry(repositoryId: Int64, filePath: String, parsed: ChangelogParsed) -> Bool {
        queue.sync {
            var exists = false
            var check: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id FROM changelog_entries WHERE repository_id=? AND file_path=? AND version=?;", -1, &check, nil) == SQLITE_OK {
                bindInt64(check, 1, repositoryId)
                bindText(check, 2, filePath)
                bindText(check, 3, parsed.version)
                exists = sqlite3_step(check) == SQLITE_ROW
            }
            sqlite3_finalize(check)

            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO changelog_entries(repository_id, file_path, version, title, body, entry_date)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(repository_id, file_path, version) DO UPDATE SET title=excluded.title, body=excluded.body, entry_date=excluded.entry_date;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, repositoryId)
                bindText(stmt, 2, filePath)
                bindText(stmt, 3, parsed.version)
                bindText(stmt, 4, parsed.title)
                bindText(stmt, 5, parsed.body)
                bindText(stmt, 6, parsed.date)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return !exists
        }
    }

    public func listChangelogEntries(repositoryId: Int64) -> [ChangelogEntryItem] {
        queue.sync {
            var out: [ChangelogEntryItem] = []
            var stmt: OpaquePointer?
            let sql = "SELECT id, repository_id, file_path, version, title, body, entry_date FROM changelog_entries WHERE repository_id=? ORDER BY id ASC;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, repositoryId)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out.append(ChangelogEntryItem(
                        id: sqlite3_column_int64(stmt, 0),
                        repositoryId: sqlite3_column_int64(stmt, 1),
                        filePath: colText(stmt, 2) ?? "",
                        version: colText(stmt, 3) ?? "",
                        title: colText(stmt, 4) ?? "",
                        body: colText(stmt, 5),
                        entryDate: colText(stmt, 6)
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    public func upsertTrackedFile(repositoryId: Int64, path: String, kind: String, sha: String?, version: String?) -> (changed: Bool, oldVersion: String?) {
        queue.sync {
            var oldSha: String?
            var oldVer: String?
            var check: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT last_sha, last_version FROM tracked_files WHERE repository_id=? AND path=?;", -1, &check, nil) == SQLITE_OK {
                bindInt64(check, 1, repositoryId)
                bindText(check, 2, path)
                if sqlite3_step(check) == SQLITE_ROW {
                    oldSha = colText(check, 0)
                    oldVer = colText(check, 1)
                }
            }
            sqlite3_finalize(check)

            let changed = (oldSha != nil && sha != nil && oldSha != sha) || (oldVer != nil && version != nil && oldVer != version)
            let now = Date()
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO tracked_files(repository_id, path, kind, last_sha, last_version, last_checked_at, last_changed_at)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(repository_id, path) DO UPDATE SET
                kind=excluded.kind, last_sha=excluded.last_sha, last_version=excluded.last_version,
                last_checked_at=excluded.last_checked_at,
                last_changed_at=CASE WHEN ? THEN excluded.last_checked_at ELSE tracked_files.last_changed_at END;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, repositoryId)
                bindText(stmt, 2, path)
                bindText(stmt, 3, kind)
                bindText(stmt, 4, sha)
                bindText(stmt, 5, version)
                bindDate(stmt, 6, now)
                bindDate(stmt, 7, changed ? now : nil)
                sqlite3_bind_int(stmt, 8, changed ? 1 : 0)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return (changed, oldVer)
        }
    }

    public func countTrackedFiles(repositoryId: Int64) -> Int {
        queue.sync {
            var cnt = 0
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM tracked_files WHERE repository_id=?;", -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, repositoryId)
                if sqlite3_step(stmt) == SQLITE_ROW { cnt = Int(sqlite3_column_int64(stmt, 0)) }
            }
            sqlite3_finalize(stmt)
            return cnt
        }
    }

    // MARK: - Version Events, Notifications & Sync Logs

    public func insertVersionEvent(
        repositoryId: Int64,
        sourceType: String,
        eventType: String,
        sourceKey: String,
        version: String?,
        title: String,
        url: String?,
        occurredAt: Date?,
        isBaseline: Bool
    ) -> Int64? {
        queue.sync {
            var check: OpaquePointer?
            var exists = false
            if sqlite3_prepare_v2(db, "SELECT id FROM version_events WHERE repository_id=? AND source_type=? AND source_key=?;", -1, &check, nil) == SQLITE_OK {
                bindInt64(check, 1, repositoryId)
                bindText(check, 2, sourceType)
                bindText(check, 3, sourceKey)
                exists = sqlite3_step(check) == SQLITE_ROW
            }
            sqlite3_finalize(check)
            if exists { return nil }

            var stmt: OpaquePointer?
            let sql = "INSERT OR IGNORE INTO version_events(repository_id, source_type, event_type, source_key, version, title, url, occurred_at, is_baseline, detected_at) VALUES(?,?,?,?,?,?,?,?,?,?);"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, repositoryId)
                bindText(stmt, 2, sourceType)
                bindText(stmt, 3, eventType)
                bindText(stmt, 4, sourceKey)
                bindText(stmt, 5, version)
                bindText(stmt, 6, title)
                bindText(stmt, 7, url)
                bindDate(stmt, 8, occurredAt)
                sqlite3_bind_int(stmt, 9, isBaseline ? 1 : 0)
                bindDate(stmt, 10, Date())
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            let id = sqlite3_last_insert_rowid(db)
            return id > 0 ? id : nil
        }
    }

    @discardableResult
    public func insertNotification(
        repositoryId: Int64,
        versionEventId: Int64?,
        channel: String,
        title: String,
        body: String?,
        url: String?,
        status: String,
        error: String?
    ) -> Bool {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT OR IGNORE INTO notifications(repository_id, version_event_id, channel, title, body, url, status, error, created_at) VALUES(?,?,?,?,?,?,?,?,?);"
            var inserted = false
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, repositoryId)
                bindInt64(stmt, 2, versionEventId)
                bindText(stmt, 3, channel)
                bindText(stmt, 4, title)
                bindText(stmt, 5, body)
                bindText(stmt, 6, url)
                bindText(stmt, 7, status)
                bindText(stmt, 8, error)
                bindDate(stmt, 9, Date())
                if sqlite3_step(stmt) == SQLITE_DONE {
                    inserted = sqlite3_changes(db) > 0
                }
            }
            sqlite3_finalize(stmt)
            return inserted
        }
    }

    public func listNotifications(limit: Int = 100) -> [NotificationItem] {
        queue.sync {
            var out: [NotificationItem] = []
            let sql = """
            SELECT n.id, n.repository_id, r.full_name, n.version_event_id, n.channel, n.title, n.body, n.url,
                   n.status, n.error, n.read_at, n.created_at
            FROM notifications n
            LEFT JOIN repositories r ON r.id = n.repository_id
            ORDER BY n.created_at DESC, n.id DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt(stmt, 1, limit)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out.append(NotificationItem(
                        id: sqlite3_column_int64(stmt, 0),
                        repositoryId: sqlite3_column_int64(stmt, 1),
                        repoFullName: colText(stmt, 2),
                        versionEventId: colInt64(stmt, 3),
                        channel: colText(stmt, 4) ?? "web",
                        title: colText(stmt, 5) ?? "",
                        body: colText(stmt, 6),
                        url: colText(stmt, 7),
                        status: colText(stmt, 8) ?? "sent",
                        error: colText(stmt, 9),
                        readAt: colDate(stmt, 10),
                        createdAt: colDate(stmt, 11) ?? Date()
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    public func markNotificationRead(id: Int64) {
        markNotificationsRead(ids: [id])
    }

    public func markNotificationsRead(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            let now = Date()
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE notifications SET read_at=? WHERE id=? AND read_at IS NULL;", -1, &stmt, nil) == SQLITE_OK {
                for id in ids {
                    sqlite3_reset(stmt)
                    bindDate(stmt, 1, now)
                    bindInt64(stmt, 2, id)
                    sqlite3_step(stmt)
                }
            }
            sqlite3_finalize(stmt)
        }
    }

    public func markAllNotificationsRead() {
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE notifications SET read_at=? WHERE read_at IS NULL;", -1, &stmt, nil) == SQLITE_OK {
                bindDate(stmt, 1, Date())
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func clearNotifications() {
        queue.sync {
            _ = try? exec("DELETE FROM notifications;")
        }
    }

    public func insertSyncLog(_ log: SyncLogItem) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO sync_logs(repository_id, trigger, mode, status, started_at, finished_at, duration_ms,
                request_count, not_modified_count, new_releases, new_tags, new_commits, new_assets,
                new_changelog, summary, error, rate_limit_remaining)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, log.repositoryId)
                bindText(stmt, 2, log.trigger)
                bindText(stmt, 3, log.mode)
                bindText(stmt, 4, log.status)
                bindDate(stmt, 5, log.startedAt)
                bindDate(stmt, 6, log.finishedAt)
                bindInt(stmt, 7, log.durationMs)
                bindInt(stmt, 8, log.requestCount)
                bindInt(stmt, 9, log.notModifiedCount)
                bindInt(stmt, 10, log.newReleases)
                bindInt(stmt, 11, log.newTags)
                bindInt(stmt, 12, log.newCommits)
                bindInt(stmt, 13, log.newAssets)
                bindInt(stmt, 14, log.newChangelog)
                bindText(stmt, 15, log.summary)
                bindText(stmt, 16, log.error)
                bindInt(stmt, 17, log.rateLimitRemaining)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func listSyncLogs(repositoryId: Int64? = nil, limit: Int = 50) -> [SyncLogItem] {
        queue.sync {
            var out: [SyncLogItem] = []
            let whereClause = repositoryId != nil ? "WHERE repository_id=?" : ""
            let sql = """
            SELECT id, repository_id, trigger, mode, status, started_at, finished_at, duration_ms,
                   request_count, not_modified_count, new_releases, new_tags, new_commits, new_assets,
                   new_changelog, summary, error, rate_limit_remaining
            FROM sync_logs \(whereClause) ORDER BY started_at DESC, id DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                var idx: Int32 = 1
                if let rid = repositoryId { bindInt64(stmt, idx, rid); idx += 1 }
                bindInt(stmt, idx, limit)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out.append(SyncLogItem(
                        id: sqlite3_column_int64(stmt, 0),
                        repositoryId: sqlite3_column_int64(stmt, 1),
                        trigger: colText(stmt, 2) ?? "manual",
                        mode: colText(stmt, 3) ?? "incremental",
                        status: colText(stmt, 4) ?? "success",
                        startedAt: colDate(stmt, 5) ?? Date(),
                        finishedAt: colDate(stmt, 6),
                        durationMs: Int(sqlite3_column_int64(stmt, 7)),
                        requestCount: Int(sqlite3_column_int64(stmt, 8)),
                        notModifiedCount: Int(sqlite3_column_int64(stmt, 9)),
                        newReleases: Int(sqlite3_column_int64(stmt, 10)),
                        newTags: Int(sqlite3_column_int64(stmt, 11)),
                        newCommits: Int(sqlite3_column_int64(stmt, 12)),
                        newAssets: Int(sqlite3_column_int64(stmt, 13)),
                        newChangelog: Int(sqlite3_column_int64(stmt, 14)),
                        summary: colText(stmt, 15),
                        error: colText(stmt, 16),
                        rateLimitRemaining: colInt(stmt, 17)
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    // MARK: - Issues & Discussions

    public func upsertIssue(_ item: IssueItem) {
        queue.sync {
            let labelsJson = (try? String(data: JSONEncoder().encode(item.labels), encoding: .utf8)) ?? "[]"
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO issues(repository_id, number, title, state, author_login, labels, comments, html_url, body, created_at_remote, updated_at_remote)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(repository_id, number) DO UPDATE SET
                title=excluded.title, state=excluded.state, author_login=excluded.author_login, labels=excluded.labels,
                comments=excluded.comments, html_url=excluded.html_url, body=COALESCE(excluded.body, issues.body),
                updated_at_remote=excluded.updated_at_remote;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, item.repositoryId)
                bindInt(stmt, 2, item.number)
                bindText(stmt, 3, item.title)
                bindText(stmt, 4, item.state)
                bindText(stmt, 5, item.authorLogin)
                bindText(stmt, 6, labelsJson)
                bindInt(stmt, 7, item.comments)
                bindText(stmt, 8, item.htmlUrl)
                bindText(stmt, 9, item.body)
                bindDate(stmt, 10, item.createdAtRemote)
                bindDate(stmt, 11, item.updatedAtRemote)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func listIssues(repositoryId: Int64, state: String? = nil) -> [IssueItem] {
        queue.sync {
            var out: [IssueItem] = []
            let stateClause = (state != nil && state != "all") ? "AND state=?" : ""
            let sql = "SELECT id, repository_id, number, title, state, author_login, labels, comments, html_url, body, created_at_remote, updated_at_remote FROM issues WHERE repository_id=? \(stateClause) ORDER BY updated_at_remote DESC LIMIT 200;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, repositoryId)
                if let s = state, s != "all" { bindText(stmt, 2, s) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let labelsData = (colText(stmt, 6) ?? "[]").data(using: .utf8) ?? Data()
                    let labels = (try? JSONDecoder().decode([LabelBadge].self, from: labelsData)) ?? []
                    out.append(IssueItem(
                        id: sqlite3_column_int64(stmt, 0),
                        repositoryId: sqlite3_column_int64(stmt, 1),
                        number: Int(sqlite3_column_int64(stmt, 2)),
                        title: colText(stmt, 3) ?? "",
                        state: colText(stmt, 4) ?? "open",
                        authorLogin: colText(stmt, 5),
                        labels: labels,
                        comments: Int(sqlite3_column_int64(stmt, 7)),
                        htmlUrl: colText(stmt, 8) ?? "",
                        body: colText(stmt, 9),
                        createdAtRemote: colDate(stmt, 10) ?? Date(),
                        updatedAtRemote: colDate(stmt, 11) ?? Date()
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    public func upsertDiscussion(_ item: DiscussionItem) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO discussions(repository_id, number, title, author_login, category_name, category_emoji, is_answered, closed, upvotes, comments, html_url, body, created_at_remote, updated_at_remote)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(repository_id, number) DO UPDATE SET
                title=excluded.title, author_login=excluded.author_login, category_name=excluded.category_name,
                category_emoji=excluded.category_emoji, is_answered=excluded.is_answered, closed=excluded.closed,
                upvotes=excluded.upvotes, comments=excluded.comments, body=COALESCE(excluded.body, discussions.body),
                updated_at_remote=excluded.updated_at_remote;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, item.repositoryId)
                bindInt(stmt, 2, item.number)
                bindText(stmt, 3, item.title)
                bindText(stmt, 4, item.authorLogin)
                bindText(stmt, 5, item.categoryName)
                bindText(stmt, 6, item.categoryEmoji)
                sqlite3_bind_int(stmt, 7, item.isAnswered ? 1 : 0)
                sqlite3_bind_int(stmt, 8, item.closed ? 1 : 0)
                bindInt(stmt, 9, item.upvotes)
                bindInt(stmt, 10, item.comments)
                bindText(stmt, 11, item.htmlUrl)
                bindText(stmt, 12, item.body)
                bindDate(stmt, 13, item.createdAtRemote)
                bindDate(stmt, 14, item.updatedAtRemote)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func listDiscussions(repositoryId: Int64) -> [DiscussionItem] {
        queue.sync {
            var out: [DiscussionItem] = []
            let sql = "SELECT id, repository_id, number, title, author_login, category_name, category_emoji, is_answered, closed, upvotes, comments, html_url, body, created_at_remote, updated_at_remote FROM discussions WHERE repository_id=? ORDER BY updated_at_remote DESC LIMIT 200;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindInt64(stmt, 1, repositoryId)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out.append(DiscussionItem(
                        id: sqlite3_column_int64(stmt, 0),
                        repositoryId: sqlite3_column_int64(stmt, 1),
                        number: Int(sqlite3_column_int64(stmt, 2)),
                        title: colText(stmt, 3) ?? "",
                        authorLogin: colText(stmt, 4),
                        categoryName: colText(stmt, 5),
                        categoryEmoji: colText(stmt, 6),
                        isAnswered: colBool(stmt, 7),
                        closed: colBool(stmt, 8),
                        upvotes: Int(sqlite3_column_int64(stmt, 9)),
                        comments: Int(sqlite3_column_int64(stmt, 10)),
                        htmlUrl: colText(stmt, 11) ?? "",
                        body: colText(stmt, 12),
                        createdAtRemote: colDate(stmt, 13) ?? Date(),
                        updatedAtRemote: colDate(stmt, 14) ?? Date()
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    // MARK: - HTTP ETag Cache

    public func getHttpCache(key: String) -> HttpCacheEntry? {
        queue.sync {
            var entry: HttpCacheEntry?
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT key, etag, last_modified, body, link_header, updated_at FROM http_cache WHERE key=?;", -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, 1, key)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    entry = HttpCacheEntry(
                        key: colText(stmt, 0) ?? key,
                        etag: colText(stmt, 1),
                        lastModified: colText(stmt, 2),
                        body: colText(stmt, 3) ?? "",
                        linkHeader: colText(stmt, 4),
                        updatedAt: colDate(stmt, 5) ?? Date()
                    )
                }
            }
            sqlite3_finalize(stmt)
            return entry
        }
    }

    public func setHttpCache(_ entry: HttpCacheEntry) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO http_cache(key, etag, last_modified, body, link_header, updated_at)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET
                etag=excluded.etag, last_modified=excluded.last_modified, body=excluded.body,
                link_header=excluded.link_header, updated_at=excluded.updated_at;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, 1, entry.key)
                bindText(stmt, 2, entry.etag)
                bindText(stmt, 3, entry.lastModified)
                bindText(stmt, 4, entry.body)
                bindText(stmt, 5, entry.linkHeader)
                bindDate(stmt, 6, entry.updatedAt)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func clearHttpCache() {
        queue.sync {
            _ = try? exec("DELETE FROM http_cache;")
            _ = try? exec("VACUUM;")
        }
    }

    // MARK: - Stats & Backup

    public func getStats() -> HubStats {
        queue.sync {
            func scalarInt64(_ sql: String) -> Int64 {
                var val: Int64 = 0
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
                    val = sqlite3_column_int64(stmt, 0)
                }
                sqlite3_finalize(stmt)
                return val
            }
            let totalRepos = Int(scalarInt64("SELECT COUNT(*) FROM repositories;"))
            let syncedRepos = Int(scalarInt64("SELECT COUNT(*) FROM repositories WHERE last_synced_at IS NOT NULL;"))
            let totalAssets = Int(scalarInt64("SELECT COUNT(*) FROM assets WHERE kind IN ('installer','package','archive','binary');"))
            let unread = Int(scalarInt64("SELECT COUNT(*) FROM notifications WHERE channel='web' AND read_at IS NULL;"))
            let cacheBytes = scalarInt64("SELECT COALESCE(SUM(LENGTH(body)), 0) FROM http_cache;")
            let dbBytes = (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0
            return HubStats(
                totalRepos: totalRepos,
                syncedRepos: syncedRepos,
                totalSoftwareAssets: totalAssets,
                unreadNotifications: unread,
                databaseBytes: dbBytes,
                cacheBytes: cacheBytes
            )
        }
    }

    public func exportBackupJSON() throws -> Data {
        let categories = listCategories()
        let reposList = listRepositories()
        let tree = CategoryTree.build(categories: categories, repos: reposList)
        let catMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        let pathMap = Dictionary(uniqueKeysWithValues: tree.map { ($0.id, $0.path) })
        let repos = reposList.map { r in
            HubBackupPayload.BackupRepoEntry(
                fullName: r.fullName,
                categoryName: r.categoryId.flatMap { catMap[$0] },
                categoryPath: r.categoryId.flatMap { pathMap[$0] },
                pollIntervalMinutes: r.pollIntervalMinutes,
                paused: r.paused,
                notifyEnabled: r.notifyEnabled,
                notifyRelease: r.notifyRelease,
                notifyPrerelease: r.notifyPrerelease,
                notifyTag: r.notifyTag,
                notifyCommit: r.notifyCommit,
                notifyChangelog: r.notifyChangelog,
                watchedFiles: r.watchedFiles
            )
        }
        let payload = HubBackupPayload(
            exportedAt: Date(),
            categories: categories,
            repos: repos,
            settings: getAllSettings()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    public func importBackupJSON(_ data: Data) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(HubBackupPayload.self, from: data)

        // Restore settings
        for (k, v) in payload.settings {
            setSetting(k, value: v)
        }

        // Restore multi-level categories preserving parent relationships
        var oldIdToNewId: [Int64: Int64] = [:]
        var existingByKey: [String: Int64] = [:]
        for c in listCategories() {
            existingByKey["\(c.parentId ?? 0):\(c.name)"] = c.id
        }
        var pending = payload.categories
        var progress = true
        while !pending.isEmpty && progress {
            progress = false
            var next: [CategoryItem] = []
            for cat in pending {
                if let oldParent = cat.parentId, oldIdToNewId[oldParent] == nil, payload.categories.contains(where: { $0.id == oldParent }) {
                    next.append(cat)
                    continue
                }
                let mappedParent = cat.parentId.flatMap { oldIdToNewId[$0] }
                let key = "\(mappedParent ?? 0):\(cat.name)"
                if let existingId = existingByKey[key] {
                    oldIdToNewId[cat.id] = existingId
                } else {
                    let newId = createCategory(name: cat.name, parentId: mappedParent)
                    existingByKey[key] = newId
                    oldIdToNewId[cat.id] = newId
                }
                progress = true
            }
            pending = next
        }
        let treeAfter = CategoryTree.build(categories: listCategories(), repos: [])
        let pathToId = Dictionary(uniqueKeysWithValues: treeAfter.map { ($0.path, $0.id) })
        let nameToId = Dictionary(listCategories().map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })

        // Restore repos
        var imported = 0
        for entry in payload.repos {
            if case let .ok(ref) = RepoParser.parse(entry.fullName) {
                let catId = entry.categoryPath.flatMap { pathToId[$0] } ?? entry.categoryName.flatMap { nameToId[$0] }
                if var pair = addRepository(ref, categoryId: catId) {
                    pair.repo.pollIntervalMinutes = entry.pollIntervalMinutes
                    pair.repo.paused = entry.paused
                    pair.repo.notifyEnabled = entry.notifyEnabled
                    pair.repo.notifyRelease = entry.notifyRelease
                    pair.repo.notifyPrerelease = entry.notifyPrerelease
                    pair.repo.notifyTag = entry.notifyTag
                    pair.repo.notifyCommit = entry.notifyCommit
                    pair.repo.notifyChangelog = entry.notifyChangelog
                    pair.repo.watchedFiles = entry.watchedFiles
                    updateRepository(pair.repo)
                    if pair.created { imported += 1 }
                }
            }
        }
        return imported
    }
}
