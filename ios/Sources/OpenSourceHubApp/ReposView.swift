import SwiftUI
import OpenSourceHubCore

struct ReposView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme

    @State private var searchText = ""
    @State private var showingAddSheet = false
    @State private var showingCategoriesSheet = false

    private var filteredRepos: [RepositoryItem] {
        app.repos.filter { repo in
            if let catId = app.selectedCategoryId {
                if catId == -1 {
                    if repo.categoryId != nil { return false }
                } else if repo.categoryId != catId {
                    return false
                }
            }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return true }
            return repo.fullName.lowercased().contains(q)
                || (repo.description?.lowercased().contains(q) ?? false)
                || (repo.latestVersion?.lowercased().contains(q) ?? false)
                || repo.platforms.contains(where: { $0.lowercased().contains(q) })
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // Search Pill (LCSign style)
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

                    // Hero "发现软件" Summary Card (LCSign inspired)
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

                    // Category filter chips
                    if !app.categories.isEmpty {
                        categoryChipsBar
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
            .refreshable {
                await app.syncAll(onlyDue: false)
            }
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
                AddRepoSheet()
            }
            .sheet(isPresented: $showingCategoriesSheet) {
                CategoriesSheet()
            }
        }
    }

    private var currentSectionTitle: String {
        if let cid = app.selectedCategoryId {
            if cid == -1 { return "未分类软件源" }
            if let cat = app.categories.first(where: { $0.id == cid }) { return cat.name }
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
                        Text("发现软件")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Text("搜索所有已同步的软件源与安装包，也可随时下拉刷新。")
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

    private var categoryChipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(title: "全部", isSelected: app.selectedCategoryId == nil) {
                    app.selectedCategoryId = nil
                }
                ForEach(app.categories) { cat in
                    categoryChip(title: "\(cat.name) (\(cat.repoCount))", isSelected: app.selectedCategoryId == cat.id) {
                        app.selectedCategoryId = cat.id
                    }
                }
                categoryChip(title: "未分类", isSelected: app.selectedCategoryId == -1) {
                    app.selectedCategoryId = -1
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func categoryChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? HubTheme.accent : HubTheme.card(scheme))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36))
                .foregroundStyle(HubTheme.accent.opacity(0.7))
            Text(app.repos.isEmpty ? "还没有添加软件源" : "没有匹配的软件源")
                .font(.headline)
            Text(app.repos.isEmpty ? "点击右上角 + 添加 GitHub 仓库（支持批量导入），即可实时监控版本、安装包与源码动态。" : "尝试更换搜索关键词或切换分类。")
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

private struct RepoCardRow: View {
    let repo: RepositoryItem
    let isSyncing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RepoIconView(repo: repo, size: 46)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(repo.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let ver = repo.latestVersion {
                            Text(ver)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(HubTheme.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(HubTheme.accentSoft)
                                .clipShape(Capsule())
                                .lineLimit(1)
                        }
                    }
                    Text(repo.fullName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSyncing {
                    ProgressView()
                        .tint(HubTheme.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            if let err = repo.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let desc = repo.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(repo.repoStatus.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(repo.platforms.prefix(4), id: \.self) { p in
                    if let plat = Platform(rawValue: p) {
                        PlatformPill(platform: plat)
                    }
                }
                if repo.platforms.isEmpty {
                    StatusBadgeView(status: repo.repoStatus)
                }
                Spacer()
                if repo.stars > 0 {
                    Label("\(repo.stars)", systemImage: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(DateFmt.relative(repo.lastSyncedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .hubCard(padding: 15, radius: 20)
    }
}
