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
        case issues = "Issues"
        case discussions = "Discussions"
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

    // Asset filters
    @State private var assetPlatformFilter: Platform? = nil
    @State private var assetSearch = ""

    // Issues GitHub-style filters
    @State private var issueSearch = ""
    @State private var issueStateFilter = "all" // all | open | closed
    @State private var issueLabelFilter: String? = nil
    @State private var issueSort = "updated" // updated | created | comments
    @State private var syncingIssues = false
    @State private var issueSyncStatus: String?

    // Discussions GitHub-style filters
    @State private var discSearch = ""
    @State private var discStateFilter = "all" // all | answered | open | closed
    @State private var discCategoryFilter: String? = nil
    @State private var discSort = "updated" // updated | upvotes | comments
    @State private var syncingDiscussions = false
    @State private var discSyncStatus: String?

    @State private var selectedIssue: IssueItem?
    @State private var selectedDiscussion: DiscussionItem?
    @State private var shareURL: URL?
    @State private var confirmDelete = false
    @State private var showingNewCategorySheet = false

    // Requirement 3: Multi-language in-app README switcher state
    @State private var activeReadmePath: String? = nil // nil = default README
    @State private var activeReadmeContent: String? = nil
    @State private var loadingReadmeVariant = false
    @State private var autoSelectedChineseForRepoId: Int64? = nil

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
            if let r = repo {
                IssueThreadSheet(repo: r, issue: issue)
                    .environmentObject(app)
            }
        }
        .sheet(item: $selectedDiscussion) { disc in
            if let r = repo {
                DiscussionThreadSheet(repo: r, discussion: disc)
                    .environmentObject(app)
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
        case .issues: return "Issues (\(issues.count))"
        case .discussions: return "Discussions (\(discussions.count))"
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
            releasesTab(repo)
        case .assets:
            assetsTab
        case .tags:
            tagsTab
        case .commits:
            commitsTab
        case .issues:
            issuesTab(repo)
        case .discussions:
            discussionsTab(repo)
        case .settings:
            logsAndSettingsTab(repo)
        }
    }

    // MARK: - Requirement 2 & 3 & 7: Overview Tab (Languages + 源码与目录 w/ Zread/DeepWiki + Changelog + Multi-language README)

    private func overviewTab(_ repo: RepositoryItem) -> some View {
        let branch = repo.defaultBranch ?? "main"
        let variants = ReadmeLanguageParser.extractVariants(
            readme: repo.readme ?? "",
            owner: repo.owner,
            repo: repo.name,
            branch: repo.defaultBranch,
            rootTree: repo.rootTree
        )
        let preferChinese = app.settings["readme.preferChinese"] != "false"
        let displayedReadme = activeReadmeContent ?? repo.readme ?? ""
        let githubReadmeUrlStr: String = {
            if let path = activeReadmePath {
                return "https://github.com/\(repo.owner)/\(repo.name)/blob/\(branch)/\(path)"
            }
            return repo.htmlUrl
        }()

        return VStack(alignment: .leading, spacing: 14) {
            // 1. Languages 语言
            if !repo.languages.isEmpty {
                LanguageBarView(languages: repo.languages)
            }

            // 2. 源码与目录 (GitHub 仓库 + Zread 文档 + DeepWiki 文档 + Source ZIP + Source TAR.GZ)
            VStack(alignment: .leading, spacing: 10) {
                Text("源码与目录").font(.headline)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let repoUrl = URL(string: repo.htmlUrl) {
                            sourceLinkPill("GitHub 仓库", url: repoUrl)
                        }
                        if let zreadUrl = URL(string: "https://zread.ai/\(repo.owner)/\(repo.name)") {
                            sourceLinkPill("Zread 文档", url: zreadUrl)
                        }
                        if let deepwikiUrl = URL(string: "https://deepwiki.com/\(repo.owner)/\(repo.name)") {
                            sourceLinkPill("DeepWiki 文档", url: deepwikiUrl)
                        }
                        if let zipUrl = URL(string: "https://github.com/\(repo.owner)/\(repo.name)/archive/refs/heads/\(branch).zip") {
                            sourceLinkPill("Source ZIP", url: zipUrl)
                        }
                        if let tarUrl = URL(string: "https://github.com/\(repo.owner)/\(repo.name)/archive/refs/heads/\(branch).tar.gz") {
                            sourceLinkPill("Source TAR.GZ", url: tarUrl)
                        }
                    }
                }

                if !repo.rootTree.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), alignment: .leading)], spacing: 6) {
                        ForEach(repo.rootTree, id: \.path) { entry in
                            let kind = entry.type == "dir" ? "tree" : "blob"
                            let urlStr = "https://github.com/\(repo.owner)/\(repo.name)/\(kind)/\(branch)/\(entry.path)"
                            Button {
                                if let u = URL(string: urlStr) { openURL(u) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: entry.type == "dir" ? "folder.fill" : "doc.text")
                                        .font(.caption2)
                                        .foregroundStyle(entry.type == "dir" ? HubTheme.accent : .secondary)
                                    Text(entry.name)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.secondary.opacity(0.09))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .hubCard()

            // 3. 最新 Changelog
            if !changelog.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("最新 Changelog").font(.headline)
                    ForEach(changelog.prefix(3)) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.version).font(.subheadline.bold()).foregroundStyle(HubTheme.accent)
                                if let d = entry.entryDate { Text(d).font(.caption2).foregroundStyle(.secondary) }
                            }
                            if let b = entry.body, !b.isEmpty {
                                RichMarkdownWebView(
                                    markdown: String(b.prefix(1500)),
                                    owner: repo.owner,
                                    repo: repo.name,
                                    branch: repo.defaultBranch
                                )
                            }
                        }
                        Divider()
                    }
                }
                .hubCard()
            }

            // 4. README (In-App Multi-Language Switcher + Prefer Chinese + Full Markdown/HTML/Math)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("README").font(.headline)
                    if let path = activeReadmePath {
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .lineLimit(1)
                    }
                    if loadingReadmeVariant {
                        ProgressView().scaleEffect(0.75).tint(HubTheme.accent)
                    }
                    Spacer()
                    Button {
                        let nextVal = !preferChinese
                        app.saveSetting("readme.preferChinese", value: nextVal ? "true" : "false")
                        if nextVal {
                            autoSelectChineseIfNeeded(repo: repo, variants: variants, force: true)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: preferChinese ? "checkmark.square.fill" : "square")
                                .foregroundStyle(preferChinese ? HubTheme.accent : .secondary)
                            Text("优先中文")
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)

                    if let ghUrl = URL(string: githubReadmeUrlStr) {
                        Button {
                            openURL(ghUrl)
                        } label: {
                            HStack(spacing: 2) {
                                Text("在 GitHub 查看")
                                Image(systemName: "arrow.up.right.square")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if activeReadmePath != nil {
                    Button {
                        activeReadmePath = nil
                        activeReadmeContent = nil
                    } label: {
                        Label("返回默认 README", systemImage: "arrow.left")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(HubTheme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(HubTheme.accentSoft)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                // Multi-language switcher bar
                if !variants.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            HStack(spacing: 3) {
                                Image(systemName: "globe")
                                Text("语言")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 2)

                            readmeLangChip(title: "默认 (README.md)", active: activeReadmePath == nil) {
                                activeReadmePath = nil
                                activeReadmeContent = nil
                            }
                            ForEach(variants) { v in
                                readmeLangChip(
                                    title: v.label,
                                    active: activeReadmePath?.lowercased() == v.path.lowercased()
                                ) {
                                    switchToReadmeVariant(path: v.path, repo: repo)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if !displayedReadme.isEmpty {
                    RichMarkdownWebView(
                        markdown: displayedReadme,
                        owner: repo.owner,
                        repo: repo.name,
                        branch: repo.defaultBranch,
                        onOpenRepoMarkdown: { mdPath in
                            let lower = mdPath.lowercased()
                            if lower == "readme.md" || lower == "readme.markdown" {
                                activeReadmePath = nil
                                activeReadmeContent = nil
                            } else {
                                switchToReadmeVariant(path: mdPath, repo: repo)
                            }
                        }
                    )
                } else {
                    Text("暂未获取到 README 内容，请先同步。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .hubCard()
            .onAppear {
                autoSelectChineseIfNeeded(repo: repo, variants: variants, force: false)
            }
            .onChange(of: repo.readmeSha) { _ in
                autoSelectChineseIfNeeded(repo: repo, variants: variants, force: false)
            }
        }
    }

    private func readmeLangChip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(active ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? HubTheme.accent : Color.secondary.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func autoSelectChineseIfNeeded(repo: RepositoryItem, variants: [ReadmeVariant], force: Bool) {
        let preferChinese = app.settings["readme.preferChinese"] != "false"
        guard preferChinese else { return }
        if !force {
            guard autoSelectedChineseForRepoId != repo.id else { return }
        }
        autoSelectedChineseForRepoId = repo.id
        if let zh = variants.first(where: { ReadmeLanguageParser.isSimplifiedChinese(label: $0.label, path: $0.path) })
            ?? variants.first(where: { $0.isChinese }) {
            switchToReadmeVariant(path: zh.path, repo: repo)
        }
    }

    private func switchToReadmeVariant(path: String, repo: RepositoryItem) {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        activeReadmePath = clean
        loadingReadmeVariant = true
        let store = app.store
        Task {
            do {
                let text = try await SyncEngine.fetchRepoFileText(store: store, repo: repo, path: clean)
                if activeReadmePath == clean {
                    activeReadmeContent = text
                }
            } catch {
                app.showToast("加载 \(clean) 失败: \(error.localizedDescription)")
            }
            loadingReadmeVariant = false
        }
    }

    private func sourceLinkPill(_ title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(HubTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(HubTheme.accentSoft)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Releases Tab

    private func releasesTab(_ repo: RepositoryItem) -> some View {
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
                            RichMarkdownWebView(
                                markdown: String(body.prefix(3500)),
                                owner: repo.owner,
                                repo: repo.name,
                                branch: repo.defaultBranch
                            )
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

    // MARK: - Assets Tab

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
                    pillFilter("全部", active: assetPlatformFilter == nil) { assetPlatformFilter = nil }
                    ForEach([Platform.ios, .macos, .windows, .linux, .android, .cross], id: \.self) { p in
                        pillFilter(p.label, active: assetPlatformFilter == p) { assetPlatformFilter = p }
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

    // MARK: - Tags & Commits

    private var tagsTab: some View {
        VStack(spacing: 10) {
            if tags.isEmpty {
                Text("暂无 Git Tags").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).hubCard(padding: 24)
            } else {
                ForEach(tags) { tag in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tag.name).font(.subheadline.weight(.semibold))
                            HStack(spacing: 8) {
                                Text(String(tag.commitSha.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if let dt = tag.commitDate {
                                    Text(DateFmt.shortDateTime(dt)).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
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

    // MARK: - Requirement 8a: Independent Issues Tab (Anti-lag Batched Sync + GitHub Filters)

    private func issuesTab(_ repo: RepositoryItem) -> some View {
        let allLabels = Array(Set(issues.flatMap { $0.labels.map(\.name) })).sorted()
        let q = issueSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = issues.filter { item in
            if issueStateFilter != "all" && item.state != issueStateFilter { return false }
            if let lbl = issueLabelFilter, !item.labels.contains(where: { $0.name == lbl }) { return false }
            if !q.isEmpty {
                let hit = item.title.lowercased().contains(q)
                    || "#\(item.number)".contains(q)
                    || (item.authorLogin?.lowercased().contains(q) ?? false)
                if !hit { return false }
            }
            return true
        }.sorted { a, b in
            switch issueSort {
            case "created": return a.createdAtRemote > b.createdAtRemote
            case "comments": return a.comments > b.comments
            default: return a.updatedAtRemote > b.updatedAtRemote
            }
        }

        return VStack(alignment: .leading, spacing: 10) {
            // Search + Sync button
            HStack(spacing: 8) {
                TextField("搜索标题、编号或作者…", text: $issueSearch)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    syncIssuesBatched(repo: repo)
                } label: {
                    if syncingIssues {
                        ProgressView().tint(HubTheme.accent).frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 34, height: 34)
                            .background(HubTheme.accentSoft)
                            .foregroundStyle(HubTheme.accent)
                            .clipShape(Circle())
                    }
                }
                .disabled(syncingIssues)
            }

            if let st = issueSyncStatus {
                Text(st).font(.caption).foregroundStyle(HubTheme.accent)
            }

            // State & Sort filters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pillFilter("全部 (\(issues.count))", active: issueStateFilter == "all") { issueStateFilter = "all" }
                    pillFilter("Open (\(issues.filter { $0.state == "open" }.count))", active: issueStateFilter == "open") { issueStateFilter = "open" }
                    pillFilter("Closed (\(issues.filter { $0.state == "closed" }.count))", active: issueStateFilter == "closed") { issueStateFilter = "closed" }
                    Menu {
                        Button("最新更新") { issueSort = "updated" }
                        Button("最新创建") { issueSort = "created" }
                        Button("最多评论") { issueSort = "comments" }
                    } label: {
                        Text("排序: \(issueSort == "created" ? "最新创建" : issueSort == "comments" ? "最多评论" : "最新更新") ▾")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(HubTheme.card(scheme))
                            .clipShape(Capsule())
                    }
                }
            }

            // Label filter chips
            if !allLabels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        pillFilter("全部标签", active: issueLabelFilter == nil) { issueLabelFilter = nil }
                        ForEach(allLabels.prefix(20), id: \.self) { lbl in
                            pillFilter(lbl, active: issueLabelFilter == lbl) {
                                issueLabelFilter = (issueLabelFilter == lbl) ? nil : lbl
                            }
                        }
                    }
                }
            }

            if filtered.isEmpty {
                Text(issues.isEmpty ? "点击右上角刷新分批同步 Issues" : "没有匹配的 Issues")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).hubCard(padding: 24)
            } else {
                ForEach(filtered) { issue in
                    Button { selectedIssue = issue } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("#\(issue.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(issue.state == "open" ? "Open" : "Closed")
                                    .font(.caption2.bold())
                                    .foregroundStyle(issue.state == "open" ? HubTheme.accent : .purple)
                                if let author = issue.authorLogin {
                                    Text("@\(author)").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Label("\(issue.comments)", systemImage: "bubble.right").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(issue.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            if !issue.labels.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 4) {
                                        ForEach(issue.labels.prefix(5), id: \.name) { l in
                                            Text(l.name)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.14))
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }
                        }
                        .hubCard(padding: 13, radius: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func syncIssuesBatched(repo: RepositoryItem) {
        syncingIssues = true
        issueSyncStatus = "正在后台分批同步 Issues…"
        let store = app.store
        Task.detached(priority: .utility) {
            do {
                let count = try await SyncEngine.syncIssues(store: store, repo: repo) { page, total in
                    Task { @MainActor in
                        issueSyncStatus = "已同步第 \(page) 页（共 \(total) 条）…"
                        issues = store.listIssues(repositoryId: repo.id)
                    }
                }
                await MainActor.run {
                    syncingIssues = false
                    issueSyncStatus = nil
                    issues = store.listIssues(repositoryId: repo.id)
                    app.showToast("已同步 \(count) 条 Issues")
                }
            } catch {
                await MainActor.run {
                    syncingIssues = false
                    issueSyncStatus = nil
                    app.showToast(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Requirement 8b: Independent Discussions Tab (Anti-lag Batched Sync + GitHub Filters)

    private func discussionsTab(_ repo: RepositoryItem) -> some View {
        let allCats = Array(Set(discussions.compactMap(\.categoryName))).sorted()
        let q = discSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = discussions.filter { d in
            switch discStateFilter {
            case "answered": if !d.isAnswered { return false }
            case "open": if d.closed { return false }
            case "closed": if !d.closed { return false }
            default: break
            }
            if let c = discCategoryFilter, d.categoryName != c { return false }
            if !q.isEmpty {
                let hit = d.title.lowercased().contains(q)
                    || "#\(d.number)".contains(q)
                    || (d.authorLogin?.lowercased().contains(q) ?? false)
                if !hit { return false }
            }
            return true
        }.sorted { a, b in
            switch discSort {
            case "upvotes": return a.upvotes > b.upvotes
            case "comments": return a.comments > b.comments
            default: return a.updatedAtRemote > b.updatedAtRemote
            }
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("搜索标题、编号或作者…", text: $discSearch)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    syncDiscussionsBatched(repo: repo)
                } label: {
                    if syncingDiscussions {
                        ProgressView().tint(HubTheme.accent).frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 34, height: 34)
                            .background(HubTheme.accentSoft)
                            .foregroundStyle(HubTheme.accent)
                            .clipShape(Circle())
                    }
                }
                .disabled(syncingDiscussions)
            }

            if let st = discSyncStatus {
                Text(st).font(.caption).foregroundStyle(HubTheme.accent)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pillFilter("全部 (\(discussions.count))", active: discStateFilter == "all") { discStateFilter = "all" }
                    pillFilter("已解答", active: discStateFilter == "answered") { discStateFilter = "answered" }
                    pillFilter("进行中", active: discStateFilter == "open") { discStateFilter = "open" }
                    pillFilter("已关闭", active: discStateFilter == "closed") { discStateFilter = "closed" }
                    Menu {
                        Button("最新更新") { discSort = "updated" }
                        Button("最多点赞") { discSort = "upvotes" }
                        Button("最多回复") { discSort = "comments" }
                    } label: {
                        Text("排序: \(discSort == "upvotes" ? "最多点赞" : discSort == "comments" ? "最多回复" : "最新更新") ▾")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(HubTheme.card(scheme))
                            .clipShape(Capsule())
                    }
                }
            }

            if !allCats.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        pillFilter("全部分类", active: discCategoryFilter == nil) { discCategoryFilter = nil }
                        ForEach(allCats, id: \.self) { cat in
                            pillFilter(cat, active: discCategoryFilter == cat) {
                                discCategoryFilter = (discCategoryFilter == cat) ? nil : cat
                            }
                        }
                    }
                }
            }

            if filtered.isEmpty {
                Text(discussions.isEmpty ? "点击右上角刷新同步 Discussions（需配置 GitHub Token）" : "没有匹配的 Discussions")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).hubCard(padding: 24)
            } else {
                ForEach(filtered) { disc in
                    Button { selectedDiscussion = disc } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("#\(disc.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                if let cat = disc.categoryName {
                                    Text(cat).font(.caption2.weight(.medium)).foregroundStyle(HubTheme.accent)
                                }
                                if disc.isAnswered {
                                    Text("已解答")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(HubTheme.accent)
                                        .clipShape(Capsule())
                                }
                                Spacer()
                                Label("\(disc.upvotes)", systemImage: "arrow.up").font(.caption2).foregroundStyle(.secondary)
                                Label("\(disc.comments)", systemImage: "bubble.right").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(disc.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                        .hubCard(padding: 13, radius: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func syncDiscussionsBatched(repo: RepositoryItem) {
        syncingDiscussions = true
        discSyncStatus = "正在后台分批同步 Discussions…"
        let store = app.store
        Task.detached(priority: .utility) {
            do {
                let count = try await SyncEngine.syncDiscussions(store: store, repo: repo) { page, total in
                    Task { @MainActor in
                        discSyncStatus = "已同步第 \(page) 页（共 \(total) 条）…"
                        discussions = store.listDiscussions(repositoryId: repo.id)
                    }
                }
                await MainActor.run {
                    syncingDiscussions = false
                    discSyncStatus = nil
                    discussions = store.listDiscussions(repositoryId: repo.id)
                    app.showToast("已同步 \(count) 条 Discussions")
                }
            } catch {
                await MainActor.run {
                    syncingDiscussions = false
                    discSyncStatus = nil
                    app.showToast(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Logs & Per-repo Settings Tab

    private func logsAndSettingsTab(_ repo: RepositoryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("单仓库监控设置").font(.headline)

                Picker("所属分类", selection: Binding(
                    get: { repo.categoryId },
                    set: { var copy = repo; copy.categoryId = $0; app.updateRepo(copy) }
                )) {
                    Text("未分类").tag(Int64?.none)
                    ForEach(app.categoryTree) { node in
                        Text(node.pickerLabel).tag(Optional(node.id))
                    }
                }
                Button {
                    showingNewCategorySheet = true
                } label: {
                    Label("+ 新建分类…", systemImage: "folder.badge.plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HubTheme.accent)
                }
                .sheet(isPresented: $showingNewCategorySheet) {
                    QuickCreateCategorySheet(initialParentId: repo.categoryId) { newId in
                        var copy = repo
                        copy.categoryId = newId
                        app.updateRepo(copy)
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

    private func pillFilter(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
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
}

// MARK: - Multi-turn Issue Thread Sheet (OP + All Replies)

private struct IssueThreadSheet: View {
    let repo: RepositoryItem
    let issue: IssueItem

    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var comments: [ThreadCommentItem] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // Original Post (OP)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(issue.title).font(.headline)
                        HStack(spacing: 8) {
                            Text("#\(issue.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(issue.state.uppercased()).font(.caption2.bold())
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background((issue.state == "open" ? HubTheme.accent : Color.purple).opacity(0.15))
                                .clipShape(Capsule())
                            if let a = issue.authorLogin { Text("@\(a)").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(DateFmt.shortDateTime(issue.createdAtRemote)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Divider()
                        RichMarkdownWebView(
                            markdown: issue.body?.isEmpty == false ? issue.body! : "（无正文内容）",
                            owner: repo.owner,
                            repo: repo.name,
                            branch: repo.defaultBranch
                        )
                    }
                    .hubCard()

                    // Replies section
                    HStack {
                        Text("全部回复 (\(comments.count))")
                            .font(.subheadline.weight(.bold))
                        Spacer()
                        if loading { ProgressView().tint(HubTheme.accent) }
                    }
                    .padding(.top, 4)

                    if let err = errorText {
                        Text("加载回复失败：\(err)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .hubCard(padding: 12)
                    } else if !loading && comments.isEmpty {
                        Text("暂无回复").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).hubCard(padding: 18)
                    } else {
                        ForEach(comments) { c in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("@\(c.authorLogin)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(HubTheme.accent)
                                    Spacer()
                                    Text(DateFmt.shortDateTime(c.createdAt))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                RichMarkdownWebView(
                                    markdown: c.body.isEmpty ? "（空内容）" : c.body,
                                    owner: repo.owner,
                                    repo: repo.name,
                                    branch: repo.defaultBranch
                                )
                            }
                            .hubCard(padding: 14, radius: 16)
                        }
                    }
                }
                .padding()
            }
            .background(HubTheme.canvas(scheme).ignoresSafeArea())
            .navigationTitle("Issue #\(issue.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let u = URL(string: issue.htmlUrl) {
                        Button("浏览器打开") { openURL(u) }
                    }
                }
            }
            .task {
                do {
                    comments = try await SyncEngine.fetchIssueComments(store: app.store, repo: repo, number: issue.number)
                } catch {
                    errorText = error.localizedDescription
                }
                loading = false
            }
        }
    }
}

// MARK: - Multi-turn Discussion Thread Sheet (OP + Comments + Nested Replies)

private struct DiscussionThreadSheet: View {
    let repo: RepositoryItem
    let discussion: DiscussionItem

    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var fullBody: String?
    @State private var comments: [ThreadCommentItem] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // Original Post
                    VStack(alignment: .leading, spacing: 10) {
                        Text(discussion.title).font(.headline)
                        HStack(spacing: 8) {
                            Text("#\(discussion.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            if let cat = discussion.categoryName {
                                Text(cat).font(.caption2).padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(HubTheme.accentSoft).clipShape(Capsule())
                            }
                            if discussion.isAnswered {
                                Text("已解答").font(.caption2.bold()).foregroundStyle(HubTheme.accent)
                            }
                            Spacer()
                            Text(DateFmt.shortDateTime(discussion.createdAtRemote)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Divider()
                        let bodyText = fullBody ?? discussion.body ?? "（无正文内容）"
                        RichMarkdownWebView(
                            markdown: bodyText.isEmpty ? "（无正文内容）" : bodyText,
                            owner: repo.owner,
                            repo: repo.name,
                            branch: repo.defaultBranch
                        )
                    }
                    .hubCard()

                    // Comments & Nested Replies
                    HStack {
                        Text("全部讨论 (\(comments.count))")
                            .font(.subheadline.weight(.bold))
                        Spacer()
                        if loading { ProgressView().tint(HubTheme.accent) }
                    }
                    .padding(.top, 4)

                    if let err = errorText {
                        Text("加载讨论失败：\(err)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .hubCard(padding: 12)
                    } else if !loading && comments.isEmpty {
                        Text("暂无回复").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).hubCard(padding: 18)
                    } else {
                        ForEach(comments) { c in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("@\(c.authorLogin)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(HubTheme.accent)
                                    if c.isAnswer {
                                        Text("已采纳答案")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(HubTheme.accent)
                                            .clipShape(Capsule())
                                    }
                                    Spacer()
                                    Text(DateFmt.shortDateTime(c.createdAt))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                RichMarkdownWebView(
                                    markdown: c.body.isEmpty ? "（空内容）" : c.body,
                                    owner: repo.owner,
                                    repo: repo.name,
                                    branch: repo.defaultBranch
                                )

                                // Nested replies
                                if !c.replies.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(c.replies) { reply in
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack {
                                                    Text("↳ @\(reply.authorLogin)")
                                                        .font(.caption2.weight(.semibold))
                                                        .foregroundStyle(.secondary)
                                                    Spacer()
                                                    Text(DateFmt.shortDateTime(reply.createdAt))
                                                        .font(.caption2)
                                                        .foregroundStyle(.tertiary)
                                                }
                                                RichMarkdownWebView(
                                                    markdown: reply.body,
                                                    owner: repo.owner,
                                                    repo: repo.name,
                                                    branch: repo.defaultBranch
                                                )
                                            }
                                            .padding(10)
                                            .background(Color.secondary.opacity(0.08))
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        }
                                    }
                                    .padding(.leading, 8)
                                }
                            }
                            .hubCard(padding: 14, radius: 16)
                        }
                    }
                }
                .padding()
            }
            .background(HubTheme.canvas(scheme).ignoresSafeArea())
            .navigationTitle("Discussion #\(discussion.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let u = URL(string: discussion.htmlUrl) {
                        Button("浏览器打开") { openURL(u) }
                    }
                }
            }
            .task {
                do {
                    let res = try await SyncEngine.fetchDiscussionThread(store: app.store, repo: repo, number: discussion.number)
                    if let b = res.body { fullBody = b }
                    comments = res.comments
                } catch {
                    errorText = error.localizedDescription
                }
                loading = false
            }
        }
    }
}
