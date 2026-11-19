import SwiftUI
import OpenSourceHubCore

struct DiscoverView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    @State private var searchText = ""
    @State private var selectedPlatform: Platform? = nil
    @State private var softwareOnly = true
    @State private var assets: [AssetItem] = []
    @State private var shareURL: URL?

    private var filtered: [AssetItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return assets }
        return assets.filter {
            $0.name.lowercased().contains(q)
                || ($0.repoFullName?.lowercased().contains(q) ?? false)
                || ($0.releaseTag?.lowercased().contains(q) ?? false)
                || $0.fileType.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Search
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索安装包名、仓库、版本号、格式…", text: $searchText)
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

                    // Platform Filter Chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterChip(title: "全部平台", active: selectedPlatform == nil) {
                                selectedPlatform = nil
                                reload()
                            }
                            ForEach([Platform.ios, .macos, .windows, .linux, .android, .cross], id: \.self) { plat in
                                filterChip(title: plat.label, active: selectedPlatform == plat) {
                                    selectedPlatform = plat
                                    reload()
                                }
                            }
                        }
                    }

                    HStack {
                        Text("共 \(filtered.count) 个附件")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Toggle("仅看安装包", isOn: $softwareOnly)
                            .labelsHidden()
                            .scaleEffect(0.82)
                            .onChange(of: softwareOnly) { _ in reload() }
                        Text("仅看软件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if filtered.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("暂无匹配的软件包")
                                .font(.headline)
                            Text("在「软件源」中添加并同步包含 Release 附件的仓库即可在此按平台发现。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .hubCard(padding: 28)
                    } else {
                        ForEach(filtered) { asset in
                            assetRow(asset)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(HubTheme.canvas(scheme).ignoresSafeArea())
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { reload() }
            .onChange(of: app.stats.totalSoftwareAssets) { _ in reload() }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
                if let url = shareURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    private func reload() {
        assets = app.store.listAssets(
            repositoryId: nil,
            platform: selectedPlatform?.rawValue,
            softwareOnly: softwareOnly,
            limit: 400
        )
    }

    private func filterChip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(active ? HubTheme.accent : HubTheme.card(scheme))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func assetRow(_ asset: AssetItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let repoName = asset.repoFullName {
                        Text("\(repoName) · \(asset.releaseTag ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let url = URL(string: asset.downloadUrl) {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(HubTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                PlatformPill(platform: asset.platformEnum)
                if asset.archEnum != .unknown {
                    Text(asset.archEnum.label)
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(asset.fileType.uppercased())
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
                Text(AssetClassifier.formatBytes(asset.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let url = URL(string: asset.downloadUrl) {
                    Button {
                        shareURL = url
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .hubCard(padding: 14, radius: 18)
    }
}
