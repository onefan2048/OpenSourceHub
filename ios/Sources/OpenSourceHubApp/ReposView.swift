import SwiftUI
import OpenSourceHubCore

struct ReposView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme

    @State private var searchText = ""
    @State private var showingAddSheet = false
    @State private var showingCategoriesSheet = false

    private var filteredRepos: [RepositoryItem] {
        let allowedCategoryIds: Set<Int64>? = {
            guard let cid = app.selectedCategoryId, cid > 0 else { return nil }
            return CategoryTree.descendantIds(of: cid, in: app.categoryTree)
        }()

        return app.repos.filter { repo in
            if let cid = app.selectedCategoryId {
                if cid == -1 {
                    if repo.categoryId != nil { return false }
                } else if let allowed = allowedCategoryIds {
                    guard let rc = repo.categoryId, allowed.contains(rc) else { return false }
                }
            }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return true }
            let catPath = app.categoryPath(for: repo.categoryId)?.lowercased() ?? ""
            return repo.fullName.lowercased().contains(q)
                || (repo.description?.lowercased().contains(q) ?? false)
                || (repo.latestVersion?.lowercased().contains(q) ?? false)
                || catPath.contains(q)
                || repo.platforms.contains(where: { $0.lowercased().contains(q) })
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // Search Pill
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索所有软件源", text: $searchText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // Hero "发现软件" Summary Card
                    heroDiscoverCard

                    // Live sync progress banner
                    if let progress = app.syncProgressText {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(HubTheme.accent)
                            Text(progress)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .hubCard(padding: 12, radius: 14)
                    }

                    // Multi-level category filter bar
                    if !app.categoryTree.isEmpty {
                        MultiLevelCategoryFilterBar(
                            tree: app.categoryTree,
                            totalCount: app.repos.count,
                            uncategorizedCount: app.repos.filter { $0.categoryId == nil }.count,
                            selectedCategoryId: $app.selectedCategoryId
                        )
                    }

                    // Section header
                    HStack {
                        Text(currentSectionTitle)
                            .font(.headline.weight(.bold))
                        Spacer()
                        Text("\(filteredRepos.count) 个")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)

                    // Repository Cards
                    if filteredRepos.isEmpty {
                        emptyStateCard
                    } else {
                        ForEach(filteredRepos) { repo in
                            NavigationLink {
                                RepoDetailView(repoId: repo.id)
                            } label: {
                                RepoCardRow(
                                    repo: repo,
                                    categoryPath: app.categoryPath(for: repo.categoryId),
                                    isSyncing: app.syncingRepoIds.contains(repo.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    Task { await app.syncRepo(id: repo.id, trigger: "manual", full: false) }
                                } label: {
                                    Label("立即同步", systemImage: "arrow.clockwise")
                                }
                                Button {
                                    Task { await app.syncRepo(id: repo.id, trigger: "manual", full: true) }
                                } label: {
                                    Label("全量同步", systemImage: "arrow.triangle.2.circlepath")
                                }
                                Button(role: .destructive) {
                                    app.deleteRepo(id: repo.id)
                                } label: {
                                    Label("删除软件源", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(HubTheme.canvas(scheme).ignoresSafeArea())
            // Requirement 4: Removed .refreshable pull-to-refresh; manual sync-all button kept in top-right toolbar.
            .navigationTitle("软件源")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingCategoriesSheet = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.body.weight(.medium))
                            .foregroundStyle(HubTheme.accent)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await app.syncAll(onlyDue: false) }
                    } label: {
                        if app.isSyncingAll {
                            ProgressView()
                                .tint(HubTheme.accent)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.body.weight(.medium))
                                .foregroundStyle(HubTheme.accent)
                        }
                    }
                    .disabled(app.isSyncingAll)

                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(HubTheme.accent)
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddRepoSheet(defaultCategoryId: app.selectedCategoryId)
            }
            .sheet(isPresented: $showingCategoriesSheet) {
                CategoriesSheet()
            }
        }
    }

    private var currentSectionTitle: String {
        if let cid = app.selectedCategoryId {
            if cid == -1 { return "未分类软件源" }
            if let node = app.categoryTree.first(where: { $0.id == cid }) { return node.path }
        }
        return "全部软件源"
    }

    private var heroDiscoverCard: some View {
        Button {
            app.selectedTab = 1
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("发现软件源")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Text("按分类、平台、格式和热度筛选所有已订阅的开源项目，点击右上角可手动全部更新。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(scheme == .dark ? 0.15 : 0.85))
                            .frame(width: 44, height: 44)
                        Image(systemName: "safari.fill")
                            .font(.title3)
                            .foregroundStyle(HubTheme.accent)
                    }
                }

                HStack(spacing: 10) {
                    heroStatBox(value: "\(app.stats.totalRepos)", label: "订阅")
                    heroStatBox(value: "\(app.stats.syncedRepos)", label: "已同步")
                    heroStatBox(value: "\(app.stats.totalSoftwareAssets)", label: "安装包")
                }
            }
            .padding(16)
            .background(HubTheme.heroGradient(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(HubTheme.accent.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func heroStatBox(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HubTheme.card(scheme).opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36))
                .foregroundStyle(HubTheme.accent.opacity(0.7))
            Text(app.repos.isEmpty ? "还没有添加软件源" : "没有匹配的软件源")
                .font(.headline)
            Text(app.repos.isEmpty ? "点击右上角 + 添加 GitHub 仓库（支持批量导入），即可监控版本、安装包与源码动态。" : "尝试更换搜索关键词或切换分类。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if app.repos.isEmpty {
                Button {
                    showingAddSheet = true
                } label: {
                    Text("添加第一个软件源")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(HubTheme.accent, in: Capsule())
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .hubCard(padding: 28)
    }
}
