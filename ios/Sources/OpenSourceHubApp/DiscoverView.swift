import SwiftUI
import OpenSourceHubCore

/// Requirement 6: Aligned with Docker's `/discover` page — searches & filters subscribed REPOSITORIES
/// by multi-level category, platform, file format, quick preset chips, and sort order.
struct DiscoverView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme

    enum QuickPreset: String, CaseIterable {
        case all = "全部"
        case recent = "最近更新"
        case release = "最新发布"
        case popular = "热门项目"
        case added = "最近添加"
        case assets = "有安装包"
        case source = "只有源码"
        case macos = "macOS"
        case windows = "Windows"
        case ios = "iOS"
        case android = "Android"
        case linux = "Linux"
        case dev = "开发工具"
    }

    enum SortOption: String, CaseIterable {
        case updated = "更新时间"
        case stars = "Star 数"
        case release = "版本时间"
        case added = "最近添加"
    }

    @State private var searchText = ""
    @State private var selectedGroupId: Int64? = nil // nil = all, -1 = uncategorized
    @State private var selectedPlatform: String = "" // "" = all
    @State private var selectedFileType: String = "" // "" = all
    @State private var selectedPreset: QuickPreset = .all
    @State private var sortOption: SortOption = .updated
    @State private var showingCategoriesSheet = false
    @State private var showingAddSheet = false

    private var availableFileTypes: [String] {
        Array(Set(app.repos.flatMap(\.fileTypes))).sorted()
    }

    private var filteredRepos: [RepositoryItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowedCatIds: Set<Int64>? = {
            guard let gid = selectedGroupId, gid > 0 else { return nil }
            return CategoryTree.descendantIds(of: gid, in: app.categoryTree)
        }()

        let rows = app.repos.filter { r in
            // Text search: name, owner, description, category path
            if !q.isEmpty {
                let catPath = app.categoryPath(for: r.categoryId)?.lowercased() ?? ""
                let match = r.name.lowercased().contains(q)
                    || r.owner.lowercased().contains(q)
                    || (r.description?.lowercased().contains(q) ?? false)
                    || catPath.contains(q)
                if !match { return false }
            }
            // Multi-level category filter
            if let gid = selectedGroupId {
                if gid == -1 {
                    if r.categoryId != nil { return false }
                } else if let allowed = allowedCatIds {
                    guard let rc = r.categoryId, allowed.contains(rc) else { return false }
                }
            }
            // Platform dropdown
            if !selectedPlatform.isEmpty, !r.platforms.contains(selectedPlatform) {
                return false
            }
            // File type dropdown
            if !selectedFileType.isEmpty, !r.fileTypes.contains(selectedFileType) {
                return false
            }
            // Quick preset filter
            switch selectedPreset {
            case .all, .recent, .popular, .added: break
            case .release: if !r.hasReleases { return false }
            case .assets: if !r.hasAssets { return false }
            case .source: if r.hasAssets { return false }
            case .macos: if !r.platforms.contains("macos") { return false }
            case .windows: if !r.platforms.contains("windows") { return false }
            case .ios: if !r.platforms.contains("ios") { return false }
            case .android: if !r.platforms.contains("android") { return false }
            case .linux: if !r.platforms.contains("linux") { return false }
            case .dev:
                let hay = "\(r.description ?? "") \(r.topics.joined(separator: " "))".lowercased()
                let isDev = hay.contains("developer") || hay.contains("development") || hay.contains("tool") || hay.contains("编程") || hay.contains("开发")
                if !isDev { return false }
            }
            return true
        }

        return rows.sorted { a, b in
            switch sortOption {
            case .stars:
                return a.stars > b.stars
            case .added:
                return a.addedAt > b.addedAt
            case .release:
                return (a.latestVersionAt ?? .distantPast) > (b.latestVersionAt ?? .distantPast)
            case .updated:
                let da = a.latestActivityAt ?? a.pushedAt ?? .distantPast
                let db = b.latestActivityAt ?? b.pushedAt ?? .distantPast
                return da > db
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Search bar
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索名称、作者、描述或分类", text: $searchText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // Filter Pickers Row (Platform / Format / Sort)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Menu {
                                Button("所有平台") { selectedPlatform = "" }
                                ForEach(Platform.allCases, id: \.rawValue) { p in
                                    Button(p.label) { selectedPlatform = p.rawValue }
                                }
                            } label: {
                                dropdownPill(
                                    title: selectedPlatform.isEmpty ? "所有平台" : (Platform(rawValue: selectedPlatform)?.label ?? selectedPlatform),
                                    active: !selectedPlatform.isEmpty
                                )
                            }

                            Menu {
                                Button("所有格式") { selectedFileType = "" }
                                ForEach(availableFileTypes, id: \.self) { ft in
                                    Button(ft) { selectedFileType = ft }
                                }
                            } label: {
                                dropdownPill(
                                    title: selectedFileType.isEmpty ? "所有格式" : selectedFileType.uppercased(),
                                    active: !selectedFileType.isEmpty
                                )
                            }

                            Menu {
                                ForEach(SortOption.allCases, id: \.self) { opt in
                                    Button(opt.rawValue) { sortOption = opt }
                                }
                            } label: {
                                dropdownPill(title: "排序: \(sortOption.rawValue)", active: false)
                            }
                        }
                    }

                    // Multi-level Category Bar (matches Docker root + sub-category bar)
                    if !app.categoryTree.isEmpty {
                        MultiLevelCategoryFilterBar(
                            tree: app.categoryTree,
                            totalCount: app.repos.count,
                            uncategorizedCount: app.repos.filter { $0.categoryId == nil }.count,
                            selectedCategoryId: $selectedGroupId
                        )
                    }

                    // Quick Preset Chips (matches Docker discover presets)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(QuickPreset.allCases, id: \.self) { preset in
                                Button {
                                    selectedPreset = preset
                                    switch preset {
                                    case .popular: sortOption = .stars
                                    case .added: sortOption = .added
                                    case .release: sortOption = .release
                                    case .recent: sortOption = .updated
                                    default: break
                                    }
                                } label: {
                                    Text(preset.rawValue)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(selectedPreset == preset ? .white : .primary)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(selectedPreset == preset ? HubTheme.accent : HubTheme.card(scheme))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Count summary
                    HStack {
                        Text(summaryLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if selectedGroupId != nil || !selectedPlatform.isEmpty || !selectedFileType.isEmpty || selectedPreset != .all || !searchText.isEmpty {
                            Button("重置筛选") {
                                searchText = ""
                                selectedGroupId = nil
                                selectedPlatform = ""
                                selectedFileType = ""
                                selectedPreset = .all
                                sortOption = .updated
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HubTheme.accent)
                        }
                    }
                    .padding(.top, 2)

                    if filteredRepos.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("没有匹配的软件源")
                                .font(.headline)
                            Text("尝试放宽分类、平台或格式筛选条件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .hubCard(padding: 28)
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
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(HubTheme.canvas(scheme).ignoresSafeArea())
            .navigationTitle("发现软件源")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingCategoriesSheet = true
                    } label: {
                        Image(systemName: "folder.badge.gearshape")
                            .foregroundStyle(HubTheme.accent)
                    }
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(HubTheme.accent)
                    }
                }
            }
            .sheet(isPresented: $showingCategoriesSheet) {
                CategoriesSheet()
            }
            .sheet(isPresented: $showingAddSheet) {
                AddRepoSheet(defaultCategoryId: selectedGroupId)
            }
        }
    }

    private var summaryLabel: String {
        if let gid = selectedGroupId {
            if gid == -1 { return "未分类中共 \(filteredRepos.count) 个软件源" }
            if let node = app.categoryTree.first(where: { $0.id == gid }) {
                return "分类「\(node.path)」中共 \(filteredRepos.count) 个软件源"
            }
        }
        return "共 \(filteredRepos.count) 个软件源"
    }

    private func dropdownPill(title: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(active ? .white : .primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(active ? HubTheme.accent : HubTheme.card(scheme))
        .clipShape(Capsule())
    }
}
