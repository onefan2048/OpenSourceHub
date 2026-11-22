import Foundation
import CryptoKit
import CommonCrypto

public struct BackupImportSummary: Equatable, Sendable {
    public var restoredCategories: Int
    public var addedRepos: Int
    public var updatedRepos: Int
    public var restoredSettings: Int
    public var restoredAccounts: Int
    public var exportedAt: String
}

public struct CloudSyncResult: Equatable, Sendable {
    public var ok: Bool
    public var action: String // "pushed" | "pulled" | "merged"
    public var summary: String
}

/// 100% compatible with the Docker/Mac `src/lib/backup.ts` backup format, AES-256-GCM PBKDF2-SHA256 encryption,
/// WebDAV (`opensource-hub-backup.json`), and private GitHub Gist cloud sync.
public enum CloudBackupEngine {
    public static let syncFilename = "opensource-hub-backup.json"
    private static let excludedSettingKeys: Set<String> = ["worker.heartbeat", "cloud.lastSyncedAt", "cloud.lastStatus"]

    // MARK: - Export

    public static func exportPayloadDict(store: SQLiteStore) -> [String: Any] {
        let cats = store.listCategories()
        let repos = store.listRepositories()
        let tree = CategoryTree.build(categories: cats, repos: repos)
        let pathById = Dictionary(uniqueKeysWithValues: tree.map { ($0.id, $0.path) })
        let sortById = Dictionary(uniqueKeysWithValues: cats.map { ($0.id, $0.sortOrder) })

        let categoriesArr: [[String: Any]] = tree.map { node in
            ["path": node.path, "sortOrder": sortById[node.id] ?? 0]
        }

        let reposArr: [[String: Any]] = repos.map { r in
            let watchedStr = (try? String(data: JSONEncoder().encode(r.watchedFiles), encoding: .utf8)) ?? "[]"
            var item: [String: Any] = [
                "provider": r.provider,
                "owner": r.owner,
                "name": r.name,
                "fullName": r.fullName,
                "htmlUrl": r.htmlUrl,
                "stars": r.stars,
                "forks": r.forks,
                "defaultBranch": r.defaultBranch ?? "main",
                "paused": r.paused,
                "notifyEnabled": r.notifyEnabled,
                "notifyRelease": r.notifyRelease,
                "notifyPrerelease": r.notifyPrerelease,
                "notifyTag": r.notifyTag,
                "notifyCommit": r.notifyCommit,
                "notifyChangelog": r.notifyChangelog,
                "watchedFiles": watchedStr,
            ]
            if let d = r.description { item["description"] = d }
            if let h = r.homepage { item["homepage"] = h }
            if let a = r.avatarUrl { item["avatarUrl"] = a }
            if let l = r.logoUrl { item["logoUrl"] = l }
            if let cid = r.categoryId, let p = pathById[cid] { item["categoryPath"] = p }
            if let n = r.note { item["note"] = n }
            if let p = r.pollIntervalMinutes { item["pollIntervalMinutes"] = p }
            return item
        }

        var cleanSettings: [String: String] = [:]
        for (k, v) in store.getAllSettings() where !excludedSettingKeys.contains(k) {
            cleanSettings[k] = v
        }

        let accountsArr: [[String: Any]] = store.listGitHubAccounts().map { a in
            var item: [String: Any] = [
                "login": a.login,
                "token": a.token,
                "enabled": a.enabled,
                "isDefault": a.isDefault,
            ]
            if let uid = a.userId { item["userId"] = uid }
            if let nm = a.name { item["name"] = nm }
            if let av = a.avatarUrl { item["avatarUrl"] = av }
            if let hu = a.htmlUrl { item["htmlUrl"] = hu }
            if let sc = a.scopes { item["scopes"] = sc }
            return item
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return [
            "app": "opensource-hub",
            "version": 2,
            "exportedAt": iso.string(from: Date()),
            "categories": categoriesArr,
            "repositories": reposArr,
            "settings": cleanSettings,
            "githubAccounts": accountsArr,
        ]
    }

    public static func exportJSONData(store: SQLiteStore, passphrase: String? = nil) throws -> Data {
        let dict = exportPayloadDict(store: store)
        let pwd = (passphrase ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if pwd.isEmpty {
            return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        }
        let plainData = try JSONSerialization.data(withJSONObject: dict, options: [])
        let env = try encryptEnvelope(plainData: plainData, exportedAt: dict["exportedAt"] as? String ?? "", passphrase: pwd)
        return try JSONSerialization.data(withJSONObject: env, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - AES-256-GCM + PBKDF2-HMAC-SHA256 (100,000 iterations, Node.js compatible)

    private static func deriveKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        let pwdData = Data(passphrase.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                pwdData.withUnsafeBytes { pwdBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwdBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pwdData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        100_000,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw NSError(domain: "CloudBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: "密钥派生失败"])
        }
        return SymmetricKey(data: derived)
    }

    private static func encryptEnvelope(plainData: Data, exportedAt: String, passphrase: String) throws -> [String: Any] {
        var salt = Data(count: 16)
        var iv = Data(count: 12)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) }

        let key = try deriveKey(passphrase: passphrase, salt: salt)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plainData, using: key, nonce: nonce)

        return [
            "app": "opensource-hub",
            "version": 2,
            "encrypted": true,
            "exportedAt": exportedAt,
            "salt": salt.base64EncodedString(),
            "iv": iv.base64EncodedString(),
            "tag": sealed.tag.base64EncodedString(),
            "data": sealed.ciphertext.base64EncodedString(),
        ]
    }

    public static func parsePayloadDict(data: Data, passphrase: String?) throws -> [String: Any] {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "CloudBackup", code: 2, userInfo: [NSLocalizedDescriptionKey: "备份内容不是有效的 JSON 对象"])
        }
        if let inner = obj["data"] as? [String: Any], obj["encrypted"] == nil {
            obj = inner
        }
        if (obj["encrypted"] as? Bool) == true {
            let pwd = (passphrase ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pwd.isEmpty else {
                throw NSError(domain: "CloudBackup", code: 3, userInfo: [NSLocalizedDescriptionKey: "该备份已加密，请先填写加密口令"])
            }
            guard let saltB64 = obj["salt"] as? String, let salt = Data(base64Encoded: saltB64),
                  let ivB64 = obj["iv"] as? String, let iv = Data(base64Encoded: ivB64),
                  let tagB64 = obj["tag"] as? String, let tag = Data(base64Encoded: tagB64),
                  let ctB64 = obj["data"] as? String, let ct = Data(base64Encoded: ctB64) else {
                throw NSError(domain: "CloudBackup", code: 4, userInfo: [NSLocalizedDescriptionKey: "加密备份头字段不完整"])
            }
            do {
                let key = try deriveKey(passphrase: pwd, salt: salt)
                let nonce = try AES.GCM.Nonce(data: iv)
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
                let decrypted = try AES.GCM.open(box, using: key)
                guard let decObj = try JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else {
                    throw NSError(domain: "CloudBackup", code: 5, userInfo: [NSLocalizedDescriptionKey: "解密后内容不是有效 JSON"])
                }
                obj = decObj
            } catch {
                throw NSError(domain: "CloudBackup", code: 6, userInfo: [NSLocalizedDescriptionKey: "解密失败：加密口令不正确或备份数据已损坏"])
            }
        }
        return obj
    }

    // MARK: - Import & Merge (Supports both Docker `repositories` and legacy iOS `repos`)

    @discardableResult
    public static func importJSONData(store: SQLiteStore, data: Data, passphrase: String? = nil) throws -> BackupImportSummary {
        let effectivePwd = passphrase ?? store.getSetting("cloud.passphrase")
        let obj = try parsePayloadDict(data: data, passphrase: effectivePwd)
        return try importPayloadDict(store: store, obj: obj)
    }

    public static func importPayloadDict(store: SQLiteStore, obj: [String: Any]) throws -> BackupImportSummary {
        let repoItems = (obj["repositories"] as? [Any]) ?? (obj["repos"] as? [Any])
        guard let repoList = repoItems else {
            throw NSError(domain: "CloudBackup", code: 7, userInfo: [NSLocalizedDescriptionKey: "备份 JSON 缺少 repositories 列表"])
        }

        var restoredCategories = 0
        var addedRepos = 0
        var updatedRepos = 0
        var restoredSettings = 0
        var restoredAccounts = 0

        // 1) Restore categories (both Docker `{ path, sortOrder }` and legacy iOS `CategoryItem` with `id/name/parentId`)
        if let rawCats = obj["categories"] as? [Any] {
            var legacyCats: [CategoryItem] = []
            for item in rawCats {
                if let str = item as? String, !str.isEmpty {
                    _ = store.ensureCategoryPath(str)
                    restoredCategories += 1
                } else if let dict = item as? [String: Any] {
                    if let path = dict["path"] as? String, !path.isEmpty {
                        _ = store.ensureCategoryPath(path)
                        restoredCategories += 1
                    } else if let name = dict["name"] as? String {
                        let id = (dict["id"] as? NSNumber)?.int64Value ?? 0
                        let pid = (dict["parentId"] as? NSNumber)?.int64Value
                        legacyCats.append(CategoryItem(id: id, name: name, parentId: pid))
                    }
                }
            }
            if !legacyCats.isEmpty {
                let tree = CategoryTree.build(categories: legacyCats, repos: [])
                for node in tree {
                    _ = store.ensureCategoryPath(node.path)
                    restoredCategories += 1
                }
            }
        }

        // 2) Restore settings
        if let settings = obj["settings"] as? [String: Any] {
            for (k, rawVal) in settings {
                guard HubSettings.defaults[k] != nil, !excludedSettingKeys.contains(k) else { continue }
                let val = String(describing: rawVal).trimmingCharacters(in: .whitespacesAndNewlines)
                if val.hasPrefix("••••••") || val.isEmpty { continue }
                store.setSetting(k, value: val)
                restoredSettings += 1
            }
        }

        // 3) Restore GitHub accounts
        if let accounts = obj["githubAccounts"] as? [[String: Any]] {
            for a in accounts {
                guard let login = a["login"] as? String, !login.isEmpty,
                      let token = a["token"] as? String, !token.isEmpty, !token.contains("••••••") else { continue }
                store.upsertGitHubAccount(
                    login: login,
                    userId: a["userId"] as? String,
                    name: a["name"] as? String,
                    avatarUrl: a["avatarUrl"] as? String,
                    htmlUrl: a["htmlUrl"] as? String,
                    token: token,
                    scopes: a["scopes"] as? String,
                    enabled: (a["enabled"] as? Bool) ?? true,
                    makeDefault: a["isDefault"] as? Bool
                )
                restoredAccounts += 1
            }
        }

        // 4) Restore repositories + multi-level category path + project note
        for rawItem in repoList {
            var dict: [String: Any] = [:]
            let fullName: String
            if let s = rawItem as? String {
                fullName = s
            } else if let d = rawItem as? [String: Any] {
                dict = d
                if let fn = d["fullName"] as? String, !fn.isEmpty {
                    fullName = fn
                } else if let o = d["owner"] as? String, let n = d["name"] as? String {
                    fullName = "\(o)/\(n)"
                } else {
                    continue
                }
            } else {
                continue
            }

            guard case let .ok(ref) = RepoParser.parse(fullName) else { continue }
            let catPath = (dict["categoryPath"] as? String) ?? (dict["categoryName"] as? String)
            let categoryId = catPath.flatMap { store.ensureCategoryPath($0) }

            guard var pair = store.addRepository(ref, categoryId: categoryId) else { continue }
            if let cid = categoryId { pair.repo.categoryId = cid }
            if let note = dict["note"] as? String { pair.repo.note = note.isEmpty ? nil : note }
            if let desc = dict["description"] as? String, pair.repo.description == nil { pair.repo.description = desc }
            if let hp = dict["homepage"] as? String, pair.repo.homepage == nil { pair.repo.homepage = hp }
            if let av = dict["avatarUrl"] as? String, pair.repo.avatarUrl == nil { pair.repo.avatarUrl = av }
            if let lg = dict["logoUrl"] as? String, pair.repo.logoUrl == nil { pair.repo.logoUrl = lg }
            if let st = (dict["stars"] as? NSNumber)?.intValue, pair.repo.stars == 0 { pair.repo.stars = st }
            if let fk = (dict["forks"] as? NSNumber)?.intValue, pair.repo.forks == 0 { pair.repo.forks = fk }
            if let br = dict["defaultBranch"] as? String, pair.repo.defaultBranch == nil { pair.repo.defaultBranch = br }
            if let pim = (dict["pollIntervalMinutes"] as? NSNumber)?.intValue { pair.repo.pollIntervalMinutes = pim }
            if let v = dict["paused"] as? Bool { pair.repo.paused = v }
            if let v = dict["notifyEnabled"] as? Bool { pair.repo.notifyEnabled = v }
            if let v = dict["notifyRelease"] as? Bool { pair.repo.notifyRelease = v }
            if let v = dict["notifyPrerelease"] as? Bool { pair.repo.notifyPrerelease = v }
            if let v = dict["notifyTag"] as? Bool { pair.repo.notifyTag = v }
            if let v = dict["notifyCommit"] as? Bool { pair.repo.notifyCommit = v }
            if let v = dict["notifyChangelog"] as? Bool { pair.repo.notifyChangelog = v }
            if let wfArr = dict["watchedFiles"] as? [String] {
                pair.repo.watchedFiles = wfArr
            } else if let wfStr = dict["watchedFiles"] as? String, let wfData = wfStr.data(using: .utf8),
                      let wfArr = try? JSONDecoder().decode([String].self, from: wfData) {
                pair.repo.watchedFiles = wfArr
            }

            store.updateRepository(pair.repo)
            if pair.created { addedRepos += 1 } else { updatedRepos += 1 }
        }

        let exportedAt = (obj["exportedAt"] as? String) ?? ISO8601DateFormatter().string(from: Date())
        return BackupImportSummary(
            restoredCategories: restoredCategories,
            addedRepos: addedRepos,
            updatedRepos: updatedRepos,
            restoredSettings: restoredSettings,
            restoredAccounts: restoredAccounts,
            exportedAt: exportedAt
        )
    }

    // MARK: - Cloud Sync (WebDAV & GitHub Gist)

    public static func runCloudSync(store: SQLiteStore, direction: String = "auto") async throws -> CloudSyncResult {
        let s = store.getAllSettings()
        let provider = (s["cloud.provider"] == "gist") ? "gist" : "webdav"
        let passphrase = s["cloud.passphrase"] ?? ""
        let providerLabel = provider == "gist" ? "GitHub Gist" : "WebDAV"

        func pullRemote() async throws -> Data? {
            if provider == "webdav" {
                let url = (s["cloud.webdav.url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else {
                    throw NSError(domain: "CloudSync", code: 10, userInfo: [NSLocalizedDescriptionKey: "请先填写 WebDAV 同步接口地址"])
                }
                return try await pullFromWebDAV(url: url, username: s["cloud.webdav.username"] ?? "", password: s["cloud.webdav.password"] ?? "")
            } else {
                let token = {
                    let g = (s["cloud.gist.token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return g.isEmpty ? store.getPreferredGitHubToken() : g
                }()
                guard !token.isEmpty else {
                    throw NSError(domain: "CloudSync", code: 11, userInfo: [NSLocalizedDescriptionKey: "请填写 GitHub Gist 同步密钥（需 Gist 读写权限）"])
                }
                return try await pullFromGist(store: store, token: token, savedId: s["cloud.gist.id"] ?? "")
            }
        }

        func pushRemote(_ data: Data) async throws {
            if provider == "webdav" {
                let url = (s["cloud.webdav.url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else {
                    throw NSError(domain: "CloudSync", code: 10, userInfo: [NSLocalizedDescriptionKey: "请先填写 WebDAV 同步接口地址"])
                }
                try await pushToWebDAV(url: url, username: s["cloud.webdav.username"] ?? "", password: s["cloud.webdav.password"] ?? "", data: data)
            } else {
                let token = {
                    let g = (s["cloud.gist.token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return g.isEmpty ? store.getPreferredGitHubToken() : g
                }()
                guard !token.isEmpty else {
                    throw NSError(domain: "CloudSync", code: 11, userInfo: [NSLocalizedDescriptionKey: "请填写 GitHub Gist 同步密钥（需 Gist 读写权限）"])
                }
                try await pushToGist(store: store, token: token, savedId: s["cloud.gist.id"] ?? "", data: data)
            }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()

        func parseTime(_ s: String?) -> Date? {
            guard let s = s, !s.isEmpty else { return nil }
            return iso.date(from: s) ?? isoFallback.date(from: s)
        }

        do {
            if direction == "pull" {
                guard let remoteData = try await pullRemote() else {
                    throw NSError(domain: "CloudSync", code: 12, userInfo: [NSLocalizedDescriptionKey: "云端尚无备份数据，请先执行一次上传或立即同步"])
                }
                let imported = try importJSONData(store: store, data: remoteData, passphrase: passphrase)
                let nowStr = iso.string(from: Date())
                let summary = "已从 \(providerLabel) 恢复（新增 \(imported.addedRepos) 个、更新 \(imported.updatedRepos) 个软件源）"
                store.setSetting("cloud.lastSyncedAt", value: nowStr)
                store.setSetting("cloud.lastStatus", value: summary)
                return CloudSyncResult(ok: true, action: "pulled", summary: summary)
            }

            if direction == "auto" {
                if let remoteData = try await pullRemote() {
                    let remoteObj = try parsePayloadDict(data: remoteData, passphrase: passphrase)
                    let lastSync = parseTime(s["cloud.lastSyncedAt"])
                    let remoteTime = parseTime(remoteObj["exportedAt"] as? String)
                    if lastSync == nil || (remoteTime != nil && remoteTime! > lastSync!) {
                        let imported = try importPayloadDict(store: store, obj: remoteObj)
                        let mergedData = try exportJSONData(store: store, passphrase: passphrase)
                        try await pushRemote(mergedData)
                        let nowStr = iso.string(from: Date())
                        let summary = "已与 \(providerLabel) 双向同步（合并新增 \(imported.addedRepos) 个、更新 \(imported.updatedRepos) 个软件源）"
                        store.setSetting("cloud.lastSyncedAt", value: nowStr)
                        store.setSetting("cloud.lastStatus", value: summary)
                        return CloudSyncResult(ok: true, action: "merged", summary: summary)
                    }
                }
            }

            let outData = try exportJSONData(store: store, passphrase: passphrase)
            try await pushRemote(outData)
            let repoCount = store.listRepositories().count
            let catCount = store.listCategories().count
            let encTag = passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "，已加密"
            let nowStr = iso.string(from: Date())
            let summary = "已同步到 \(providerLabel)（共 \(repoCount) 个软件源、\(catCount) 个分类\(encTag)）"
            store.setSetting("cloud.lastSyncedAt", value: nowStr)
            store.setSetting("cloud.lastStatus", value: summary)
            return CloudSyncResult(ok: true, action: "pushed", summary: summary)
        } catch {
            store.setSetting("cloud.lastStatus", value: "同步失败：\(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - WebDAV Transport

    private static func resolveWebDAVURL(_ raw: String) throws -> URL {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u.lowercased().hasPrefix("http://") || u.lowercased().hasPrefix("https://") else {
            throw NSError(domain: "CloudSync", code: 13, userInfo: [NSLocalizedDescriptionKey: "WebDAV 同步接口必须以 http:// 或 https:// 开头"])
        }
        let target = u.lowercased().hasSuffix(".json") ? u : (u.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + syncFilename)
        guard let url = URL(string: target) else {
            throw NSError(domain: "CloudSync", code: 14, userInfo: [NSLocalizedDescriptionKey: "WebDAV URL 格式无效"])
        }
        return url
    }

    private static func pullFromWebDAV(url rawUrl: String, username: String, password: String) async throws -> Data? {
        let url = try resolveWebDAVURL(rawUrl)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 25
        let auth = Data("\(username):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        req.setValue("OpenSource-Hub-iOS/4.0", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw NSError(domain: "CloudSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "WebDAV 认证失败（HTTP \(http.statusCode)），请检查同步账户与同步密钥"])
        }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "CloudSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "WebDAV 读取失败（HTTP \(http.statusCode)）"])
        }
        return data
    }

    private static func pushToWebDAV(url rawUrl: String, username: String, password: String, data: Data) async throws {
        let url = try resolveWebDAVURL(rawUrl)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.timeoutInterval = 25
        let auth = Data("\(username):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("OpenSource-Hub-iOS/4.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = data

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw NSError(domain: "CloudSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "WebDAV 认证失败（HTTP \(http.statusCode)），请检查同步账户与同步密钥"])
        }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "CloudSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "WebDAV 写入失败（HTTP \(http.statusCode)）"])
        }
    }

    // MARK: - GitHub Gist Transport

    private static func findExistingGistId(store: SQLiteStore, token: String, savedId: String) async throws -> String? {
        let cleanId = savedId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanId.isEmpty, let url = URL(string: "https://api.github.com/gists/\(cleanId)") {
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("OpenSource-Hub-iOS/4.0", forHTTPHeaderField: "User-Agent")
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) { return cleanId }
                if http.statusCode == 401 {
                    throw NSError(domain: "CloudSync", code: 401, userInfo: [NSLocalizedDescriptionKey: "GitHub Gist 同步密钥无效（HTTP 401）"])
                }
            }
        }

        guard let listURL = URL(string: "https://api.github.com/gists?per_page=50") else { return nil }
        var req = URLRequest(url: listURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("OpenSource-Hub-iOS/4.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 {
                throw NSError(domain: "CloudSync", code: 401, userInfo: [NSLocalizedDescriptionKey: "GitHub Gist 同步密钥无效（HTTP 401）"])
            }
            guard (200...299).contains(http.statusCode) else { return nil }
        }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for g in arr {
            if let files = g["files"] as? [String: Any], files[syncFilename] != nil, let gid = g["id"] as? String {
                store.setSetting("cloud.gist.id", value: gid)
                return gid
            }
        }
        return nil
    }

    private static func pullFromGist(store: SQLiteStore, token: String, savedId: String) async throws -> Data? {
        guard let gid = try await findExistingGistId(store: store, token: token, savedId: savedId),
              let url = URL(string: "https://api.github.com/gists/\(gid)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("OpenSource-Hub-iOS/4.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = obj["files"] as? [String: Any],
              let fileObj = files[syncFilename] as? [String: Any],
              let content = fileObj["content"] as? String else {
            return nil
        }
        return Data(content.utf8)
    }

    private static func pushToGist(store: SQLiteStore, token: String, savedId: String, data: Data) async throws {
        let content = String(data: data, encoding: .utf8) ?? "{}"
        let gid = try await findExistingGistId(store: store, token: token, savedId: savedId)
        let bodyObj: [String: Any] = [
            "description": "OpenSource Hub 数据云同步备份（自动生成）",
            "public": false,
            "files": [syncFilename: ["content": content]],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyObj)

        let urlStr = gid != nil ? "https://api.github.com/gists/\(gid!)" : "https://api.github.com/gists"
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = gid != nil ? "PATCH" : "POST"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("OpenSource-Hub-iOS/4.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = bodyData

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "CloudSync", code: code, userInfo: [NSLocalizedDescriptionKey: "写入私密 Gist 失败（HTTP \(code)），请确认 PAT 具有 Gist 读写权限"])
        }
        if gid == nil,
           let created = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           let newId = created["id"] as? String {
            store.setSetting("cloud.gist.id", value: newId)
        }
    }
}
