import Foundation

/// Multi-account GitHub login & Issue/Discussion reply tracking engine (aligned with Docker `src/lib/accounts.ts`).
public enum AccountSyncEngine {
    private static func parseISO(_ str: String?) -> Date? {
        guard let str = str, !str.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: str)
    }

    private static func summarizeBody(_ s: String?) -> String {
        guard var text = s, !text.isEmpty else { return "" }
        text = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "[代码]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]+\)"#, with: "[图片]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<img\b[^>]*>"#, with: "[图片]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(240))
    }

    /// Validates a GitHub Personal Access Token via `GET /user` and saves/updates the account.
    public static func loginGitHubAccount(store: SQLiteStore, rawToken: String, makeDefault: Bool? = nil) async throws -> GitHubAccountItem {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw NSError(domain: "AccountSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "请输入 GitHub Personal Access Token"])
        }
        guard let url = URL(string: "https://api.github.com/user") else {
            throw NSError(domain: "AccountSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "无效请求地址"])
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("OpenSource-Hub-iOS/4.0", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "AccountSync", code: 3, userInfo: [NSLocalizedDescriptionKey: "无 HTTP 响应"])
        }
        if http.statusCode == 401 {
            throw NSError(domain: "AccountSync", code: 401, userInfo: [NSLocalizedDescriptionKey: "Token 无效或已过期（HTTP 401）"])
        }
        guard (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String, !login.isEmpty else {
            throw NSError(domain: "AccountSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "验证 GitHub 账号失败（HTTP \(http.statusCode)）"])
        }

        let userId = (json["id"] as? NSNumber).map { String($0.int64Value) }
        let name = json["name"] as? String
        let avatarUrl = json["avatar_url"] as? String
        let htmlUrl = (json["html_url"] as? String) ?? "https://github.com/\(login)"
        let scopes = http.value(forHTTPHeaderField: "x-oauth-scopes")

        let accId = store.upsertGitHubAccount(
            login: login,
            userId: userId,
            name: name,
            avatarUrl: avatarUrl,
            htmlUrl: htmlUrl,
            token: token,
            scopes: scopes,
            enabled: true,
            makeDefault: makeDefault
        )
        // Also keep settings["github.token"] synced with the default account for backwards compatibility
        if store.getGitHubAccount(id: accId)?.isDefault == true || store.getSetting("github.token").isEmpty {
            store.setSetting("github.token", value: token)
        }
        guard let saved = store.getGitHubAccount(id: accId) else {
            throw NSError(domain: "AccountSync", code: 4, userInfo: [NSLocalizedDescriptionKey: "保存账号失败"])
        }
        return saved
    }

    private static let authoredRepliesQuery = """
    query($issueQuery:String!,$discQuery:String!){
      issues:search(query:$issueQuery,type:ISSUE,first:25){
        nodes{
          ... on Issue {
            number title url updatedAt
            repository{nameWithOwner}
            comments(last:10){
              nodes{
                id body url createdAt
                author{login avatarUrl}
              }
            }
          }
        }
      }
      discussions:search(query:$discQuery,type:DISCUSSION,first:25){
        nodes{
          ... on Discussion {
            number title url updatedAt
            repository{nameWithOwner}
            comments(last:10){
              nodes{
                id body url createdAt isAnswer
                author{login avatarUrl}
                replies(last:5){
                  nodes{
                    id body url createdAt isAnswer
                    author{login avatarUrl}
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    /// Syncs replies on Issues & Discussions authored by (or participated in by) a single GitHub account.
    public static func syncAccountNotifications(
        store: SQLiteStore,
        accountId: Int64,
        onLocalNotify: NotificationDispatcher.LocalNotifyHandler? = nil
    ) async -> (added: Int, error: String?) {
        guard let acc = store.getGitHubAccount(id: accountId), acc.enabled else {
            return (0, nil)
        }
        let gh = GitHubClient(store: store, token: acc.token)
        let myLogin = acc.login.lowercased()
        let isFirstSync = (acc.lastSyncedAt == nil && acc.totalCount == 0)
        var added = 0

        func recordReply(
            sourceKey: String,
            kind: String,
            repoFullName: String,
            number: Int,
            title: String,
            reason: String,
            actorLogin: String?,
            actorAvatar: String?,
            body: String?,
            url: String,
            occurredAt: Date
        ) {
            let item = AccountNotificationItem(
                id: 0,
                accountId: acc.id,
                accountLogin: acc.login,
                sourceKey: sourceKey,
                kind: kind,
                repoFullName: repoFullName,
                number: number,
                title: title,
                reason: reason,
                actorLogin: actorLogin,
                actorAvatar: actorAvatar,
                body: body,
                url: url,
                occurredAt: occurredAt,
                readAt: nil,
                createdAt: Date()
            )
            if store.insertAccountNotification(item) {
                added += 1
                if !isFirstSync {
                    let actorPrefix = actorLogin.map { "@\($0) 回复: " } ?? ""
                    onLocalNotify?("[\(repoFullName) #\(number)] \(title)", "\(actorPrefix)\(body ?? "")", url)
                }
            }
        }

        do {
            let json = try await gh.graphql(query: authoredRepliesQuery, variables: [
                "issueQuery": "author:\(acc.login) is:issue sort:updated-desc",
                "discQuery": "author:\(acc.login) sort:updated-desc",
            ])
            let data = (json["data"] as? [String: Any]) ?? [:]

            // 1) Authored Issues comments
            let issueNodes = ((data["issues"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            for iss in issueNodes {
                guard let number = iss["number"] as? Int,
                      let repoFullName = (iss["repository"] as? [String: Any])?["nameWithOwner"] as? String else { continue }
                let issTitle = (iss["title"] as? String) ?? "#\(number)"
                let issUrl = (iss["url"] as? String) ?? "https://github.com/\(repoFullName)/issues/\(number)"
                let comments = ((iss["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
                for c in comments {
                    guard let cid = c["id"] as? String else { continue }
                    let author = c["author"] as? [String: Any]
                    let actor = author?["login"] as? String
                    if let actor = actor, actor.lowercased() == myLogin { continue }
                    recordReply(
                        sourceKey: "issue_comment:\(cid)",
                        kind: "issue",
                        repoFullName: repoFullName,
                        number: number,
                        title: issTitle,
                        reason: "author",
                        actorLogin: actor,
                        actorAvatar: author?["avatarUrl"] as? String,
                        body: summarizeBody(c["body"] as? String),
                        url: (c["url"] as? String) ?? issUrl,
                        occurredAt: parseISO(c["createdAt"] as? String) ?? Date()
                    )
                }
            }

            // 2) Authored Discussions comments & nested replies
            let discNodes = ((data["discussions"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            for disc in discNodes {
                guard let number = disc["number"] as? Int,
                      let repoFullName = (disc["repository"] as? [String: Any])?["nameWithOwner"] as? String else { continue }
                let discTitle = (disc["title"] as? String) ?? "#\(number)"
                let discUrl = (disc["url"] as? String) ?? "https://github.com/\(repoFullName)/discussions/\(number)"
                let comments = ((disc["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
                for c in comments {
                    guard let cid = c["id"] as? String else { continue }
                    let author = c["author"] as? [String: Any]
                    let actor = author?["login"] as? String
                    let isAnswer = (c["isAnswer"] as? Bool) ?? false
                    if actor == nil || actor!.lowercased() != myLogin {
                        recordReply(
                            sourceKey: "disc_comment:\(cid)",
                            kind: "discussion",
                            repoFullName: repoFullName,
                            number: number,
                            title: discTitle,
                            reason: isAnswer ? "answer" : "author",
                            actorLogin: actor,
                            actorAvatar: author?["avatarUrl"] as? String,
                            body: summarizeBody(c["body"] as? String),
                            url: (c["url"] as? String) ?? discUrl,
                            occurredAt: parseISO(c["createdAt"] as? String) ?? Date()
                        )
                    }
                    let replies = ((c["replies"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
                    for r in replies {
                        guard let rid = r["id"] as? String else { continue }
                        let rAuthor = r["author"] as? [String: Any]
                        let rActor = rAuthor?["login"] as? String
                        if let rActor = rActor, rActor.lowercased() == myLogin { continue }
                        let rAnswer = (r["isAnswer"] as? Bool) ?? false
                        recordReply(
                            sourceKey: "disc_reply:\(rid)",
                            kind: "discussion",
                            repoFullName: repoFullName,
                            number: number,
                            title: discTitle,
                            reason: rAnswer ? "answer" : "author",
                            actorLogin: rActor,
                            actorAvatar: rAuthor?["avatarUrl"] as? String,
                            body: summarizeBody(r["body"] as? String),
                            url: (r["url"] as? String) ?? (c["url"] as? String) ?? discUrl,
                            occurredAt: parseISO(r["createdAt"] as? String) ?? Date()
                        )
                    }
                }
            }

            store.updateGitHubAccountSyncResult(id: acc.id, error: nil)
            return (added, nil)
        } catch {
            let msg = error.localizedDescription
            store.updateGitHubAccountSyncResult(id: acc.id, error: msg)
            return (added, msg)
        }
    }

    public static func syncAllAccountsNotifications(
        store: SQLiteStore,
        onLocalNotify: NotificationDispatcher.LocalNotifyHandler? = nil
    ) async -> Int {
        let accounts = store.listGitHubAccounts().filter(\.enabled)
        var totalAdded = 0
        for acc in accounts {
            let res = await syncAccountNotifications(store: store, accountId: acc.id, onLocalNotify: onLocalNotify)
            totalAdded += res.added
        }
        return totalAdded
    }
}
