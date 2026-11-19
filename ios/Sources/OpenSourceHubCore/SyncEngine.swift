import Foundation

public enum SyncEngine {
    private static func parseISO(_ str: String?) -> Date? {
        guard let str = str, !str.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: str)
    }

    public static func syncRepository(
        store: SQLiteStore,
        repoId: Int64,
        trigger: String = "manual",
        full: Bool = false,
        onLocalNotify: NotificationDispatcher.LocalNotifyHandler? = nil
    ) async -> (result: SyncResult, rateLimit: RateLimitInfo) {
        let start = Date()
        guard var repo = store.getRepository(id: repoId) else {
            return (SyncResult(ok: false, status: "failed", errors: ["仓库不存在"], summary: "仓库不存在"), RateLimitInfo())
        }

        let token = store.getSetting("github.token")
        let gh = GitHubClient(store: store, token: token)
        let isBaseline = !repo.baselineEstablished
        let mode = (full || isBaseline) ? "full" : "incremental"
        let maxReleasePages = max(1, store.getIntSetting("sync.maxReleasePages", fallback: 10))
        let maxTagPages = max(1, store.getIntSetting("sync.maxTagPages", fallback: 5))
        let initialCommits = max(5, min(100, store.getIntSetting("sync.initialCommitCount", fallback: 30)))
        let staleDays = max(30, store.getIntSetting("sync.staleDays", fallback: 365))

        var result = SyncResult(ok: true, status: "success")
        var notifyQueue: [NotifyPayload] = []

        func recordEvent(sourceType: String, eventType: String, sourceKey: String, version: String?, title: String, url: String?, occurredAt: Date?) {
            let historical = occurredAt != nil && repo.baselineAt != nil && occurredAt! < repo.baselineAt!.addingTimeInterval(-86400)
            let baselineFlag = isBaseline || historical
            guard let evId = store.insertVersionEvent(
                repositoryId: repo.id,
                sourceType: sourceType,
                eventType: eventType,
                sourceKey: sourceKey,
                version: version,
                title: title,
                url: url,
                occurredAt: occurredAt,
                isBaseline: baselineFlag
            ) else { return }

            guard !baselineFlag, repo.notifyEnabled else { return }
            let shouldNotify: Bool
            switch eventType {
            case "release_published": shouldNotify = repo.notifyRelease
            case "prerelease_published": shouldNotify = repo.notifyPrerelease
            case "tag_created": shouldNotify = repo.notifyTag
            case "commit_pushed": shouldNotify = repo.notifyCommit
            case "changelog_entry", "version_file_changed": shouldNotify = repo.notifyChangelog
            default: shouldNotify = false
            }
            if shouldNotify {
                notifyQueue.append(NotifyPayload(
                    repositoryId: repo.id,
                    versionEventId: evId,
                    repoFullName: repo.fullName,
                    title: "[\(repo.fullName)] \(title)",
                    body: version.map { "新版本: \($0)" },
                    url: url ?? repo.htmlUrl
                ))
            }
        }

        // 1. Repo base metadata
        let base = "/repos/\(repo.owner)/\(repo.name)"
        do {
            let resp: GitHubResponse<GhRepoDTO> = try await gh.request(path: base)
            let r = resp.data
            repo.providerRepoId = String(r.id)
            repo.description = r.description
            repo.homepage = (r.homepage?.isEmpty == false) ? r.homepage : nil
            repo.htmlUrl = r.html_url
            repo.avatarUrl = r.owner.avatar_url
            repo.stars = r.stargazers_count
            repo.forks = r.forks_count
            repo.watchers = r.subscribers_count ?? r.watchers_count
            if let lic = r.license {
                repo.license = (lic.spdx_id != nil && lic.spdx_id != "NOASSERTION") ? lic.spdx_id : lic.name
            } else {
                repo.license = nil
            }
            repo.language = r.language
            repo.topics = r.topics ?? []
            repo.defaultBranch = r.default_branch
            repo.isArchived = r.archived
            repo.isFork = r.fork
            repo.pushedAt = parseISO(r.pushed_at)
            repo.accessible = true
            repo.lastError = nil

            let newKey = r.full_name.lowercased()
            if newKey != repo.fullNameKey, store.findRepository(fullNameKey: newKey) == nil {
                repo.owner = r.owner.login
                repo.name = r.name
                repo.fullName = r.full_name
                repo.fullNameKey = newKey
            }
        } catch let err as GitHubAPIError {
            result.ok = false
            result.status = "failed"
            result.errors.append(err.message)
            result.summary = err.message
            if err.isNotFound { repo.accessible = false }
            repo.lastError = err.message
            repo.consecutiveFailures += 1
            repo.lastSyncedAt = Date()
            repo.lastSyncStatus = "failed"
            store.updateRepository(repo)
            logSync(store: store, repoId: repo.id, trigger: trigger, mode: mode, result: result, gh: gh, start: start)
            return (result, gh.rateLimit)
        } catch {
            result.ok = false
            result.status = "failed"
            result.errors.append(error.localizedDescription)
            result.summary = error.localizedDescription
            repo.lastError = error.localizedDescription
            repo.consecutiveFailures += 1
            repo.lastSyncedAt = Date()
            repo.lastSyncStatus = "failed"
            store.updateRepository(repo)
            logSync(store: store, repoId: repo.id, trigger: trigger, mode: mode, result: result, gh: gh, start: start)
            return (result, gh.rateLimit)
        }

        let updatedBase = "/repos/\(repo.owner)/\(repo.name)"

        // 2. Releases + Assets
        do {
            var nextPath: String? = "\(updatedBase)/releases?per_page=100"
            var page = 0
            while let path = nextPath, page < maxReleasePages {
                page += 1
                let resp: GitHubResponse<[GhReleaseDTO]> = try await gh.request(path: path)
                var pageInserted = 0
                for rel in resp.data {
                    let item = ReleaseItem(
                        id: 0,
                        repositoryId: repo.id,
                        providerId: String(rel.id),
                        tagName: rel.tag_name,
                        name: rel.name,
                        body: rel.body,
                        isPrerelease: rel.prerelease,
                        isDraft: rel.draft,
                        isLatest: false,
                        publishedAt: parseISO(rel.published_at),
                        htmlUrl: rel.html_url,
                        zipballUrl: rel.zipball_url,
                        tarballUrl: rel.tarball_url,
                        authorLogin: rel.author?.login,
                        assetCount: rel.assets.count
                    )
                    let (relId, inserted) = store.upsertRelease(item)
                    if inserted {
                        result.newReleases += 1
                        pageInserted += 1
                    }
                    for a in rel.assets {
                        let cls = AssetClassifier.classify(name: a.name, contentType: a.content_type)
                        let assetItem = AssetItem(
                            id: 0,
                            repositoryId: repo.id,
                            releaseId: relId,
                            providerId: String(a.id),
                            name: a.name,
                            label: a.label,
                            contentType: a.content_type,
                            size: a.size,
                            downloadCount: a.download_count,
                            downloadUrl: a.browser_download_url,
                            sha256: AssetClassifier.parseDigest(a.digest),
                            platform: cls.platform.rawValue,
                            arch: cls.arch.rawValue,
                            fileType: cls.fileType,
                            kind: cls.kind.rawValue,
                            confidence: cls.confidence,
                            createdAtRemote: parseISO(a.created_at)
                        )
                        if store.upsertAsset(assetItem) {
                            result.newAssets += 1
                        }
                    }
                    if !rel.draft {
                        let evType = rel.prerelease ? "prerelease_published" : "release_published"
                        let title = (rel.name?.isEmpty == false) ? rel.name! : rel.tag_name
                        recordEvent(
                            sourceType: "release",
                            eventType: evType,
                            sourceKey: String(rel.id),
                            version: rel.tag_name,
                            title: title,
                            url: rel.html_url,
                            occurredAt: parseISO(rel.published_at) ?? parseISO(rel.created_at)
                        )
                    }
                }
                if mode == "incremental" && (resp.notModified || pageInserted == 0) {
                    break
                }
                nextPath = resp.nextLink
            }
        } catch {
            result.errors.append("Releases: \(error.localizedDescription)")
        }

        // 3. Git Tags
        do {
            var nextPath: String? = "\(updatedBase)/tags?per_page=100"
            var page = 0
            while let path = nextPath, page < maxTagPages {
                page += 1
                let resp: GitHubResponse<[GhTagDTO]> = try await gh.request(path: path)
                var pageInserted = 0
                for t in resp.data {
                    let tagItem = TagItem(
                        id: 0,
                        repositoryId: repo.id,
                        name: t.name,
                        commitSha: t.commit.sha,
                        commitDate: nil,
                        zipballUrl: t.zipball_url,
                        tarballUrl: t.tarball_url
                    )
                    if store.upsertTag(tagItem) {
                        result.newTags += 1
                        pageInserted += 1
                        recordEvent(
                            sourceType: "tag",
                            eventType: "tag_created",
                            sourceKey: t.name,
                            version: t.name,
                            title: "Tag \(t.name)",
                            url: "\(repo.htmlUrl)/releases/tag/\(t.name)",
                            occurredAt: nil
                        )
                    }
                }
                if mode == "incremental" && (resp.notModified || pageInserted == 0) {
                    break
                }
                nextPath = resp.nextLink
            }
        } catch {
            result.errors.append("Tags: \(error.localizedDescription)")
        }

        // 4. Default branch Commits
        var headChanged = false
        if let branch = repo.defaultBranch, !branch.isEmpty {
            do {
                let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch
                let resp: GitHubResponse<[GhCommitDTO]> = try await gh.request(path: "\(updatedBase)/commits?sha=\(encodedBranch)&per_page=\(initialCommits)")
                if let firstSha = resp.data.first?.sha {
                    if repo.headSha != firstSha {
                        headChanged = true
                        repo.headSha = firstSha
                    }
                }
                for c in resp.data {
                    let firstLine = c.commit.message.components(separatedBy: "\n").first ?? c.commit.message
                    let commitDate = parseISO(c.commit.committer?.date ?? c.commit.author?.date)
                    let commitItem = CommitItem(
                        id: 0,
                        repositoryId: repo.id,
                        sha: c.sha,
                        shortSha: String(c.sha.prefix(7)),
                        message: c.commit.message,
                        authorName: c.commit.author?.name,
                        authorLogin: c.author?.login,
                        committedAt: commitDate,
                        htmlUrl: c.html_url,
                        branch: branch
                    )
                    if store.upsertCommit(commitItem) {
                        result.newCommits += 1
                        recordEvent(
                            sourceType: "commit",
                            eventType: "commit_pushed",
                            sourceKey: c.sha,
                            version: String(c.sha.prefix(7)),
                            title: firstLine,
                            url: c.html_url,
                            occurredAt: commitDate
                        )
                    }
                }
            } catch let err as GitHubAPIError where err.statusCode == 409 {
                // Empty repo has no commits
            } catch {
                result.errors.append("Commits: \(error.localizedDescription)")
            }
        }

        // 5. Root tree -> README, Logo, Changelog, Version Files
        if isBaseline || headChanged || full || repo.readme == nil {
            do {
                let resp: GitHubResponse<[GhContentEntryDTO]> = try await gh.request(path: "\(updatedBase)/contents")
                let files = resp.data.filter { $0.type == "file" }

                // Logo
                if let logo = files.first(where: { ChangelogParser.isLogoName($0.name) }), let dl = logo.download_url {
                    repo.logoUrl = dl
                }

                // README
                if let readmeFile = files.first(where: { ChangelogParser.isReadmeName($0.name) }), readmeFile.sha != repo.readmeSha {
                    if let raw = try? await gh.requestRawText(path: "\(updatedBase)/contents/\(readmeFile.path)") {
                        repo.readme = String(raw.prefix(120_000))
                        repo.readmeSha = readmeFile.sha
                    }
                }

                // Changelog
                if let changelogFile = files.first(where: { ChangelogParser.isChangelogName($0.name) }) {
                    let (changed, _) = store.upsertTrackedFile(repositoryId: repo.id, path: changelogFile.path, kind: "changelog", sha: changelogFile.sha, version: nil)
                    if isBaseline || changed || store.listChangelogEntries(repositoryId: repo.id).isEmpty {
                        if let raw = try? await gh.requestRawText(path: "\(updatedBase)/contents/\(changelogFile.path)") {
                            let entries = ChangelogParser.parseChangelog(raw, limit: 50)
                            for entry in entries {
                                if store.upsertChangelogEntry(repositoryId: repo.id, filePath: changelogFile.path, parsed: entry) {
                                    result.newChangelog += 1
                                    recordEvent(
                                        sourceType: "changelog",
                                        eventType: "changelog_entry",
                                        sourceKey: "\(changelogFile.path)@\(entry.version)",
                                        version: entry.version,
                                        title: entry.title,
                                        url: "\(repo.htmlUrl)/blob/\(repo.defaultBranch ?? "main")/\(changelogFile.path)",
                                        occurredAt: nil
                                    )
                                }
                            }
                        }
                    }
                }

                // Version files
                for vf in files where ChangelogParser.versionFiles.contains(where: { $0.lowercased() == vf.name.lowercased() }) {
                    if let raw = try? await gh.requestRawText(path: "\(updatedBase)/contents/\(vf.path)") {
                        let ver = ChangelogParser.parseVersionFile(path: vf.path, text: raw)
                        let (changed, oldVer) = store.upsertTrackedFile(repositoryId: repo.id, path: vf.path, kind: "version_file", sha: vf.sha, version: ver)
                        if changed, let v = ver, v != oldVer {
                            recordEvent(
                                sourceType: "changelog",
                                eventType: "version_file_changed",
                                sourceKey: "\(vf.path)@\(v)",
                                version: v,
                                title: "\(vf.name) 更新至 \(v)",
                                url: "\(repo.htmlUrl)/blob/\(repo.defaultBranch ?? "main")/\(vf.path)",
                                occurredAt: Date()
                            )
                        }
                    }
                }
            } catch let err as GitHubAPIError where err.statusCode == 404 {
                // Empty repo
            } catch {
                result.errors.append("Files: \(error.localizedDescription)")
            }
        }

        // 6. Recompute aggregated repo metadata & status
        let releases = store.listReleases(repositoryId: repo.id).filter { !$0.isDraft }
        let assets = store.listAssets(repositoryId: repo.id)
        let softwareAssets = assets.filter { $0.kindEnum.isSoftware }
        let tags = store.listTags(repositoryId: repo.id)
        let commits = store.listCommits(repositoryId: repo.id, limit: 1)
        let changelog = store.listChangelogEntries(repositoryId: repo.id)

        repo.hasReleases = !releases.isEmpty
        repo.hasTags = !tags.isEmpty
        repo.hasAssets = !softwareAssets.isEmpty
        repo.platforms = Array(Set(softwareAssets.map { $0.platform }.filter { $0 != "unknown" })).sorted()
        repo.fileTypes = Array(Set(softwareAssets.map { $0.fileType })).sorted()

        // Latest version priority: formal release > prerelease > tag > changelog > commit
        if let formalRel = releases.first(where: { !$0.isPrerelease }) ?? releases.first {
            repo.latestVersion = formalRel.tagName
            repo.latestVersionSource = "release"
            repo.latestVersionAt = formalRel.publishedAt
        } else if let latestTag = VersionUtils.selectLatestTag(tags) ?? tags.first {
            repo.latestVersion = latestTag.name
            repo.latestVersionSource = "tag"
            repo.latestVersionAt = latestTag.commitDate
        } else if let cl = changelog.first {
            repo.latestVersion = cl.version
            repo.latestVersionSource = "changelog"
            repo.latestVersionAt = nil
        } else if let cm = commits.first {
            repo.latestVersion = cm.shortSha
            repo.latestVersionSource = "commit"
            repo.latestVersionAt = cm.committedAt
        }

        let activityDates = [repo.pushedAt, releases.first?.publishedAt, commits.first?.committedAt].compactMap { $0 }
        repo.latestActivityAt = activityDates.max()

        repo.status = VersionUtils.computeStatus(
            accessible: repo.accessible,
            isArchived: repo.isArchived,
            synced: true,
            releaseCount: releases.count,
            softwareAssetCount: softwareAssets.count,
            tagCount: tags.count,
            commitCount: commits.count,
            trackedFileCount: store.countTrackedFiles(repositoryId: repo.id),
            lastActivityAt: repo.latestActivityAt,
            staleDays: staleDays
        ).rawValue

        if result.errors.isEmpty {
            repo.baselineEstablished = true
            if repo.baselineAt == nil { repo.baselineAt = Date() }
            repo.lastSyncStatus = "success"
            repo.consecutiveFailures = 0
        } else {
            result.status = "partial"
            repo.lastSyncStatus = "partial"
        }

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        repo.lastSyncedAt = Date()
        repo.lastSyncDurationMs = durationMs
        let intervalMin = repo.pollIntervalMinutes ?? store.getIntSetting("poll.defaultIntervalMinutes", fallback: 15)
        repo.nextSyncAt = Date().addingTimeInterval(Double(intervalMin * 60))
        store.updateRepository(repo)

        // Dispatch notifications for non-baseline new events
        if !notifyQueue.isEmpty {
            await NotificationDispatcher.dispatch(store: store, items: notifyQueue, onLocalNotify: onLocalNotify)
        }

        result.requestCount = gh.requestCount
        result.notModifiedCount = gh.notModifiedCount
        result.durationMs = durationMs
        let parts = [
            result.newReleases > 0 ? "+\(result.newReleases) Release" : nil,
            result.newAssets > 0 ? "+\(result.newAssets) 附件" : nil,
            result.newTags > 0 ? "+\(result.newTags) Tag" : nil,
            result.newCommits > 0 ? "+\(result.newCommits) Commit" : nil,
            result.newChangelog > 0 ? "+\(result.newChangelog) Changelog" : nil,
        ].compactMap { $0 }
        result.summary = parts.isEmpty ? "已是最新（304: \(gh.notModifiedCount)）" : parts.joined(separator: "、")

        logSync(store: store, repoId: repo.id, trigger: trigger, mode: mode, result: result, gh: gh, start: start)
        return (result, gh.rateLimit)
    }

    // MARK: - Community Sync (Issues & Discussions)

    public static func syncIssues(store: SQLiteStore, repo: RepositoryItem) async throws -> Int {
        let gh = GitHubClient(store: store, token: store.getSetting("github.token"))
        let resp: GitHubResponse<[GhIssueDTO]> = try await gh.request(path: "/repos/\(repo.owner)/\(repo.name)/issues?state=all&sort=updated&direction=desc&per_page=50")
        var count = 0
        for item in resp.data where item.pull_request == nil {
            let issue = IssueItem(
                id: 0,
                repositoryId: repo.id,
                number: item.number,
                title: item.title,
                state: item.state,
                authorLogin: item.user?.login,
                labels: (item.labels ?? []).map { LabelBadge(name: $0.name, color: $0.color) },
                comments: item.comments,
                htmlUrl: item.html_url,
                body: item.body,
                createdAtRemote: parseISO(item.created_at) ?? Date(),
                updatedAtRemote: parseISO(item.updated_at) ?? Date()
            )
            store.upsertIssue(issue)
            count += 1
        }
        return count
    }

    public static func syncDiscussions(store: SQLiteStore, repo: RepositoryItem) async throws -> Int {
        let gh = GitHubClient(store: store, token: store.getSetting("github.token"))
        let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            discussions(first: 30, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number
                title
                url
                body
                closed
                upvoteCount
                isAnswered
                createdAt
                updatedAt
                author { login }
                category { name emoji }
                comments { totalCount }
              }
            }
          }
        }
        """
        let json = try await gh.graphql(query: query, variables: ["owner": repo.owner, "name": repo.name])
        guard let data = json["data"] as? [String: Any],
              let repoObj = data["repository"] as? [String: Any],
              let discObj = repoObj["discussions"] as? [String: Any],
              let nodes = discObj["nodes"] as? [[String: Any]] else {
            return 0
        }
        var count = 0
        for n in nodes {
            guard let number = n["number"] as? Int, let title = n["title"] as? String else { continue }
            let author = (n["author"] as? [String: Any])?["login"] as? String
            let cat = n["category"] as? [String: Any]
            let commentsCount = ((n["comments"] as? [String: Any])?["totalCount"] as? Int) ?? 0
            let disc = DiscussionItem(
                id: 0,
                repositoryId: repo.id,
                number: number,
                title: title,
                authorLogin: author,
                categoryName: cat?["name"] as? String,
                categoryEmoji: cat?["emoji"] as? String,
                isAnswered: (n["isAnswered"] as? Bool) ?? false,
                closed: (n["closed"] as? Bool) ?? false,
                upvotes: (n["upvoteCount"] as? Int) ?? 0,
                comments: commentsCount,
                htmlUrl: (n["url"] as? String) ?? repo.htmlUrl,
                body: n["body"] as? String,
                createdAtRemote: parseISO(n["createdAt"] as? String) ?? Date(),
                updatedAtRemote: parseISO(n["updatedAt"] as? String) ?? Date()
            )
            store.upsertDiscussion(disc)
            count += 1
        }
        return count
    }

    private static func logSync(store: SQLiteStore, repoId: Int64, trigger: String, mode: String, result: SyncResult, gh: GitHubClient, start: Date) {
        store.insertSyncLog(SyncLogItem(
            id: 0,
            repositoryId: repoId,
            trigger: trigger,
            mode: mode,
            status: result.status,
            startedAt: start,
            finishedAt: Date(),
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            requestCount: gh.requestCount,
            notModifiedCount: gh.notModifiedCount,
            newReleases: result.newReleases,
            newTags: result.newTags,
            newCommits: result.newCommits,
            newAssets: result.newAssets,
            newChangelog: result.newChangelog,
            summary: result.summary,
            error: result.errors.isEmpty ? nil : result.errors.joined(separator: "; "),
            rateLimitRemaining: gh.rateLimit.remaining
        ))
    }
}
