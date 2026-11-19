import SwiftUI
import UIKit
import OpenSourceHubCore

struct RepoDetailView: View {
    let repoId: Int64

    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    enum DetailTab: String, CaseIterable {
        case overview = "概览"
        case releases = "版本"
        case assets = "下载"
        case tags = "Tags"
        case commits = "Commits"
        case community = "社区"
        case settings = "日志与设置"
    }

    @State private var tab: DetailTab = .overview
    @State private var releases: [ReleaseItem] = []
    @State private var assets: [AssetItem] = []
    @State private var tags: [TagItem] = []
    @State private var commits: [CommitItem] = []
    @State private var changelog: [ChangelogEntryItem] = []
    @State private var issues: [IssueItem] = []
    @State private var discussions: [DiscussionItem] = []
    @State private var logs: [SyncLogItem] = []

    @State private var assetPlatformFilter: Platform? = nil
    @State private var assetSearch = ""
    @State private var communityMode = 0 // 0 = Issues, 1 = Discussions
    @State private var syncingCommunity = false
    @State private var selectedIssue: IssueItem?
    @State private var selectedDiscussion: DiscussionItem?
    @State private var shareURL: URL?
    @State private var confirmDelete = false

    private var repo: RepositoryItem? {
        app.repos.first(where: { $0.id == repoId }) ?? app.store.getRepository(id: repoId)
    }

    var body: some View {
        Group {
            if let repo = repo {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        headerCard(repo)
                        tabBar
                        tabContent(repo)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
                .background(HubTheme.canvas(scheme).ignoresSafeArea())
                .refreshable {
                    await app.syncRepo(id: repoId, trigger: "manual", full: false)
                    loadDetail()
                }
                .navigationTitle(repo.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task {
                                await app.syncRepo(id: repoId, trigger: "manual", full: false)
                                loadDetail()
                            }
                        } label: {
                            if app.syncingRepoIds.contains(repoId) {
                                ProgressView().tint(HubTheme.accent)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                }
                .onAppear { loadDetail() }
                .onChange(of: app.syncingRepoIds.contains(repoId)) { syncing in
                    if !syncing { loadDetail() }
                }
            } else {
                Text("软件源不存在").foregroundStyle(.secondary)
            }
        }
        .sheet(item: $selectedIssue) { issue in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(issue.title).font(.headline)
                        HStack {
                            Text("#\(issue.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(issue.state.uppercased()).font(.caption2.bold())
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background((issue.state == "open" ? HubTheme.accent : Color.purple).opacity(0.15))
                                .clipShape(Capsule())
                            if let a = issue.authorLogin { Text("@\(a)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Divider()
                        MarkdownBlockView(markdown: issue.body?.isEmpty == false ? issue.body! : "（无正文内容）")
                    }
                    .padding()
                }
                .navigationTitle("Issue #\(issue.number)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if let u = URL(string: issue.htmlUrl) {
                            Button("浏览器打开") { openURL(u) }
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedDiscussion) { disc in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(disc.title).font(.headline)
                        HStack {
                            Text("#\(disc.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            if let cat = disc.categoryName {
                                Text(cat).font(.caption2).padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(HubTheme.accentSoft).clipShape(Capsule())
                            }
                            if disc.isAnswered {
                                Text("已解答").font(.caption2.bold()).foregroundStyle(HubTheme.accent)
                            }
                        }
                        Divider()
                        MarkdownBlockView(markdown: disc.body?.isEmpty == false ? disc.body! : "（无正文内容）")
                    }
                    .padding()
                }
                .navigationTitle("Discussion #\(disc.number)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if let u = URL(string: disc.htmlUrl) {
                            Button("浏览器打开") { openURL(u) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let u = shareURL { ShareSheet(items: [u]) }
        }
        .confirmationDialog("确认删除此软件源及其全部本地历史？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除软件源", role: .destructive) {
                app.deleteRepo(id: repoId)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func loadDetail() {
        releases = app.store.listReleases(repositoryId: repoId)
        assets = app.store.listAssets(repositoryId: repoId)
        tags = app.store.listTags(repositoryId: repoId)
        commits = app.store.listCommits(repositoryId: repoId, limit: 80)
        changelog = app.store.listChangelogEntries(repositoryId: repoId)
        issues = app.store.listIssues(repositoryId: repoId)
        discussions = app.store.listDiscussions(repositoryId: repoId)
        logs = app.store.listSyncLogs(repositoryId: repoId, limit: 30)
    }

    // MARK: - Header Card

    private func headerCard(_ repo: RepositoryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RepoIconView(repo: repo, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(repo.fullName)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        StatusBadgeView(status: repo.repoStatus)
                        if let ver = repo.latestVersion {
                            Text(ver)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(HubTheme.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(HubTheme.accentSoft)
                                .clipShape(Capsule())
                        }
                    }
                }
                Spacer()
            }

            if let desc = repo.description, !desc.isEmpty {
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Label("\(repo.stars)", systemImage: "star")
                Label("\(repo.forks)", systemImage: "tuningfork")
                if let lang = repo.language { Label(lang, systemImage: "chevron.left.forwardslash.chevron.right") }
                if let lic = repo.license { Label(lic, systemImage: "doc.text") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    Task {
                        await app.syncRepo(id: repoId, trigger: "manual", full: false)
                        loadDetail()
                    }
                } label: {
                    Label("立即同步", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(HubTheme.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(app.syncingRepoIds.contains(repoId))

                if let url = URL(string: repo.htmlUrl) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("GitHub", systemImage: "safari")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(HubTheme.accentSoft)
                            .foregroundStyle(HubTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
        .hubCard()
    }

    // MARK: - Horizontal Pill Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DetailTab.allCases, id: \.self) { t in
                    Button {
                        tab = t
                    } label: {
                        Text(tabTitle(t))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tab == t ? .white : .primary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(tab == t ? HubTheme.accent : HubTheme.card(scheme))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func tabTitle(_ t: DetailTab) -> String {
        switch t {
        case .releases: return "版本 (\(releases.count))"
        case .assets: return "下载 (\(assets.filter { $0.kindEnum.isSoftware }.count))"
        case .tags: return "Tags (\(tags.count))"
        case .commits: return "Commits (\(commits.count))"
        case .community: return "社区 (\(issues.count + discussions.count))"
        default: return t.rawValue
        }
    }

    // MARK: - Tab Views

    @ViewBuilder
    private func tabContent(_ repo: RepositoryItem) -> some View {
        switch tab {
        case .overview:
            overviewTab(repo)
        case .releases:
            releasesTab
        case .assets:
            assetsTab
        case .tags:
            tagsTab
        case .commits:
            commitsTab
        case .community:
            communityTab(repo)
        case .settings:
            logsAndSettingsTab(repo)
        }
    }

    private func overviewTab(_ repo: RepositoryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !changelog.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("最新 Changelog").font(.headline)
                    ForEach(changelog.prefix(3)) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.version).font(.subheadline.bold()).foregroundStyle(HubTheme.accent)
                                if let d = entry.entryDate { Text(d).font(.caption2).foregroundStyle(.secondary) }
                            }
                            if let b = entry.body, !b.isEmpty {
                                Text(b).font(.caption).foregroundStyle(.secondary).lineLimit(5)
                            }
                        }
                        Divider()
                    }
                }
                .hubCard()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("README").font(.headline)
                if let readme = repo.readme, !readme.isEmpty {
                    MarkdownBlockView(markdown: readme)
                } else {
                    Text("暂未获取到 README 内容，请先同步。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .hubCard()
        }
    }

    private var releasesTab: some View {
        VStack(spacing: 12) {
            if releases.isEmpty {
                Text("此仓库暂无 Release 记录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .hubCard(padding: 24)
            } else {
                ForEach(releases) { rel in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(rel.name?.isEmpty == false ? rel.name! : rel.tagName)
                                .font(.headline)
                            if rel.isPrerelease {
                                Text("预发布")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            Text(DateFmt.shortDateTime(rel.publishedAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let body = rel.body, !body.isEmpty {
                            MarkdownBlockView(markdown: String(body.prefix(2500)))
                        }

                        let relAssets = assets.filter { $0.releaseId == rel.id }
                        if !relAssets.isEmpty {
                            Divider()
                            Text("附件 (\(relAssets.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(relAssets) { a in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(a.name).font(.caption.weight(.medium)).lineLimit(1)
                                        Text("\(a.platformEnum.label) · \(AssetClassifier.formatBytes(a.size))")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let u = URL(string: a.downloadUrl) {
                                        Button { openURL(u) } label: {
                                            Image(systemName: "arrow.down.circle.fill")
                                                .foregroundStyle(HubTheme.accent)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .hubCard()
                }
            }
        }
    }

    private var assetsTab: some View {
        let filtered = assets.filter { a in
            if let p = assetPlatformFilter, a.platformEnum != p { return false }
            let q = assetSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return q.isEmpty || a.name.lowercased().contains(q) || a.fileType.lowercased().contains(q)
        }
        return VStack(alignment: .leading, spacing: 10) {
            TextField("筛选文件名 / 格式…", text: $assetSearch)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    platformFilterButton("全部", active: assetPlatformFilter == nil) { assetPlatformFilter = nil }
                    ForEach([Platform.ios, .macos, .windows, .linux, .android, .cross], id: \.self) { p in
                        platformFilterButton(p.label, active: assetPlatformFilter == p) { assetPlatformFilter = p }
                    }
                }
            }

            if filtered.isEmpty {
                Text("暂无匹配的下载附件")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).hubCard(padding: 24)
            } else {
                ForEach(filtered) { a in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Spacer()
                            if let u = URL(string: a.downloadUrl) {
                                Button { openURL(u) } label: {
                                    Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(HubTheme.accent)
                                }
                                Button { shareURL = u } label: {
                                    Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack(spacing: 6) {
                            PlatformPill(platform: a.platformEnum)
                            Text(a.fileType.uppercased()).font(.caption2.monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12)).clipShape(Capsule())
                            if a.archEnum != .unknown {
                                Text(a.archEnum.label).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(AssetClassifier.formatBytes(a.size)).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let sha = a.sha256 {
                            Button {
                                UIPasteboard.general.string = sha
                                app.showToast("已复制 SHA256")
                            } label: {
                                Text("SHA256: \(sha.prefix(16))…（点击复制）")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .hubCard(padding: 13, radius: 16)
                }
            }
        }
    }

    private func platformFilterButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? .white : .primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(active ? HubTheme.accent : HubTheme.card(scheme))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var tagsTab: some View {
        VStack(spacing: 10) {
            if tags.isEmpty {
                Text("暂无 Git Tags").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).hubCard(padding: 24)
            } else {
                ForEach(tags) { tag in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tag.name).font(.subheadline.weight(.semibold))
                            Text(String(tag.commitSha.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let zip = tag.zipballUrl, let u = URL(string: zip) {
                            Button("ZIP") { openURL(u) }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HubTheme.accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(HubTheme.accentSoft)
                                .clipShape(Capsule())
                        }
                    }
                    .hubCard(padding: 13, radius: 16)
                }
            }
        }
    }

    private var commitsTab: some View {
        VStack(spacing: 10) {
            if commits.isEmpty {
                Text("暂无 Commit 记录").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).hubCard(padding: 24)
            } else {
                ForEach(commits) { c in
                    Button {
                        if let u = URL(string: c.htmlUrl) { openURL(u) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.message.components(separatedBy: "\n").first ?? c.message)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            HStack {
                                Text(c.shortSha).font(.caption2.monospaced()).foregroundStyle(HubTheme.accent)
                                Text(c.authorLogin ?? c.authorName ?? "").font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(DateFmt.shortDateTime(c.committedAt)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .hubCard(padding: 13, radius: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func communityTab(_ repo: RepositoryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("社区类型", selection: $communityMode) {
                    Text("Issues (\(issues.count))").tag(0)
                    Text("Discussions (\(discussions.count))").tag(1)
                }
                .pickerStyle(.segmented)

                Button {
                    syncingCommunity = true
                    Task {
                        do {
                            if communityMode == 0 {
                                let n = try await SyncEngine.syncIssues(store: app.store, repo: repo)
                                app.showToast("已同步 \(n) 条 Issues")
                            } else {
                                let n = try await SyncEngine.syncDiscussions(store: app.store, repo: repo)
                                app.showToast("已同步 \(n) 条 Discussions")
                            }
                        } catch {
                            app.showToast(error.localizedDescription)
                        }
                        syncingCommunity = false
                        loadDetail()
                    }
                } label: {
                    if syncingCommunity {
                        ProgressView().tint(HubTheme.accent)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .padding(8)
                            .background(HubTheme.accentSoft)
                            .clipShape(Circle())
                    }
                }
            }

            if communityMode == 0 {
                if issues.isEmpty {
                    Text("点击右上角刷新同步 Issues").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).hubCard(padding: 24)
                } else {
                    ForEach(issues) { issue in
                        Button { selectedIssue = issue } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("#\(issue.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(issue.state == "open" ? "Open" : "Closed")
                                        .font(.caption2.bold())
                                        .foregroundStyle(issue.state == "open" ? HubTheme.accent : .purple)
                                    Spacer()
                                    Label("\(issue.comments)", systemImage: "bubble.right").font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(issue.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            }
                            .hubCard(padding: 13, radius: 16)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                if discussions.isEmpty {
                    Text("点击刷新同步 Discussions（需在设置中配置 GitHub Token）")
                        .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).hubCard(padding: 24)
                } else {
                    ForEach(discussions) { disc in
                        Button { selectedDiscussion = disc } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("#\(disc.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    if let cat = disc.categoryName { Text(cat).font(.caption2).foregroundStyle(HubTheme.accent) }
                                    Spacer()
                                    Label("\(disc.upvotes)", systemImage: "arrow.up").font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(disc.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            }
                            .hubCard(padding: 13, radius: 16)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func logsAndSettingsTab(_ repo: RepositoryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Per-repo Settings Card
            VStack(alignment: .leading, spacing: 12) {
                Text("单仓库监控设置").font(.headline)

                Picker("所属分类", selection: Binding(
                    get: { repo.categoryId },
                    set: { var copy = repo; copy.categoryId = $0; app.updateRepo(copy) }
                )) {
                    Text("未分类").tag(Int64?.none)
                    ForEach(app.categories) { cat in
                        Text(cat.name).tag(Optional(cat.id))
                    }
                }

                Toggle("暂停自动同步", isOn: Binding(
                    get: { repo.paused },
                    set: { var copy = repo; copy.paused = $0; app.updateRepo(copy) }
                ))
                Toggle("启用更新通知", isOn: Binding(
                    get: { repo.notifyEnabled },
                    set: { var copy = repo; copy.notifyEnabled = $0; app.updateRepo(copy) }
                ))
                if repo.notifyEnabled {
                    Toggle("正式 Release 通知", isOn: Binding(
                        get: { repo.notifyRelease },
                        set: { var copy = repo; copy.notifyRelease = $0; app.updateRepo(copy) }
                    ))
                    Toggle("预发布 Prerelease 通知", isOn: Binding(
                        get: { repo.notifyPrerelease },
                        set: { var copy = repo; copy.notifyPrerelease = $0; app.updateRepo(copy) }
                    ))
                    Toggle("Git Tag 通知", isOn: Binding(
                        get: { repo.notifyTag },
                        set: { var copy = repo; copy.notifyTag = $0; app.updateRepo(copy) }
                    ))
                    Toggle("默认分支 Commit 通知", isOn: Binding(
                        get: { repo.notifyCommit },
                        set: { var copy = repo; copy.notifyCommit = $0; app.updateRepo(copy) }
                    ))
                }

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Text("删除此软件源")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.12))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .hubCard()

            // Sync Logs
            VStack(alignment: .leading, spacing: 10) {
                Text("最近同步记录").font(.headline)
                if logs.isEmpty {
                    Text("暂无同步记录").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(logs.prefix(15)) { log in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(log.status.uppercased())
                                    .font(.caption2.bold())
                                    .foregroundStyle(log.status == "success" ? HubTheme.accent : (log.status == "partial" ? .orange : .red))
                                Text("\(log.mode) · \(log.durationMs)ms · 请求 \(log.requestCount) (304: \(log.notModifiedCount))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(DateFmt.shortDateTime(log.startedAt)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            if let s = log.summary { Text(s).font(.caption) }
                            if let e = log.error { Text(e).font(.caption2).foregroundStyle(.red) }
                        }
                        Divider()
                    }
                }
            }
            .hubCard()
        }
    }
}
