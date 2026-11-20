import SwiftUI
import UIKit
import WebKit
import OpenSourceHubCore

// MARK: - Repo Icon (Avatar or LCSign-style gradient initial square)

struct RepoIconView: View {
    let repo: RepositoryItem
    var size: CGFloat = 46

    var body: some View {
        let iconURL = (repo.logoUrl ?? repo.avatarUrl).flatMap(URL.init(string:))
        Group {
            if let url = iconURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        fallbackSquare
                    }
                }
            } else {
                fallbackSquare
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }

    private var fallbackSquare: some View {
        ZStack {
            HubTheme.repoIconGradient(for: repo.fullName)
            Text(String(repo.name.prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Status & Platform Badges

struct StatusBadgeView: View {
    let status: RepoStatus

    private var color: Color {
        switch status {
        case .releaseWithAssets: return HubTheme.accent
        case .releaseNoAssets: return .blue
        case .tagsOnly: return .purple
        case .commitsOnly, .sourceOnly: return .orange
        case .inaccessible: return .red
        default: return .secondary
        }
    }

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

struct PlatformPill: View {
    let platform: Platform

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: platform.sfSymbol)
                .font(.system(size: 10))
            Text(platform.label)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(HubTheme.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(HubTheme.accentSoft)
        .clipShape(Capsule())
    }
}

// MARK: - Shared Repository Card Row

struct RepoCardRow: View {
    let repo: RepositoryItem
    let categoryPath: String?
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
                    HStack(spacing: 6) {
                        Text(repo.fullName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let path = categoryPath, !path.isEmpty {
                            Text(path)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.indigo)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.indigo.opacity(0.12))
                                .clipShape(Capsule())
                                .lineLimit(1)
                        }
                    }
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

// MARK: - Multi-Level Category Filter Bar (Root + Sub-categories + Breadcrumb)

struct MultiLevelCategoryFilterBar: View {
    @Environment(\.colorScheme) private var scheme
    let tree: [CategoryTreeNode]
    let totalCount: Int
    let uncategorizedCount: Int
    @Binding var selectedCategoryId: Int64?

    private var rootNodes: [CategoryTreeNode] {
        tree.filter { $0.parentId == nil }
    }

    private var activeNode: CategoryTreeNode? {
        guard let cid = selectedCategoryId, cid > 0 else { return nil }
        return tree.first(where: { $0.id == cid })
    }

    private var activeRootId: Int64? {
        guard let node = activeNode else { return nil }
        return node.ancestorIds.first ?? node.id
    }

    private var subParent: CategoryTreeNode? {
        guard let node = activeNode else { return nil }
        if node.childrenCount > 0 { return node }
        if let pid = node.parentId { return tree.first(where: { $0.id == pid }) }
        return nil
    }

    private var subNodes: [CategoryTreeNode] {
        guard let parent = subParent else { return [] }
        return tree.filter { $0.parentId == parent.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Root categories bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(title: "全部 (\(totalCount))", active: selectedCategoryId == nil) {
                        selectedCategoryId = nil
                    }
                    ForEach(rootNodes) { node in
                        let suffix = node.childrenCount > 0 ? " ▸" : ""
                        chip(
                            title: "\(node.name) (\(node.totalCount))\(suffix)",
                            active: activeRootId == node.id
                        ) {
                            selectedCategoryId = node.id
                        }
                    }
                    chip(title: "未分类 (\(uncategorizedCount))", active: selectedCategoryId == -1) {
                        selectedCategoryId = -1
                    }
                }
                .padding(.vertical, 2)
            }

            // Sub-categories bar when a parent or child category is active
            if let parent = subParent, !subNodes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("全部分类 > \(parent.path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip(
                                title: "全部「\(parent.name)」(\(parent.totalCount))",
                                active: selectedCategoryId == parent.id
                            ) {
                                selectedCategoryId = parent.id
                            }
                            ForEach(subNodes) { child in
                                let suffix = child.childrenCount > 0 ? " ▸" : ""
                                chip(
                                    title: "\(child.name) (\(child.totalCount))\(suffix)",
                                    active: selectedCategoryId == child.id
                                ) {
                                    selectedCategoryId = child.id
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .background(HubTheme.card(scheme).opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
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
}

// MARK: - Language Bar (GitHub-style stacked color progress bar)

struct LanguageBarView: View {
    let languages: [String: Int]

    private static let colorMap: [String: Color] = [
        "Swift": Color(red: 0.94, green: 0.32, blue: 0.22),
        "Dart": Color(red: 0.00, green: 0.71, blue: 0.67),
        "JavaScript": Color(red: 0.95, green: 0.87, blue: 0.31),
        "TypeScript": Color(red: 0.19, green: 0.47, blue: 0.78),
        "Python": Color(red: 0.21, green: 0.45, blue: 0.65),
        "Kotlin": Color(red: 0.66, green: 0.48, blue: 1.00),
        "Go": Color(red: 0.00, green: 0.68, blue: 0.85),
        "Rust": Color(red: 0.87, green: 0.65, blue: 0.52),
        "Java": Color(red: 0.69, green: 0.45, blue: 0.10),
        "C": Color(red: 0.33, green: 0.33, blue: 0.33),
        "C++": Color(red: 0.95, green: 0.29, blue: 0.49),
        "C#": Color(red: 0.09, green: 0.53, blue: 0.00),
        "Shell": Color(red: 0.54, green: 0.88, blue: 0.32),
        "HTML": Color(red: 0.89, green: 0.30, blue: 0.15),
        "CSS": Color(red: 0.34, green: 0.24, blue: 0.49),
        "Vue": Color(red: 0.25, green: 0.72, blue: 0.51),
        "Objective-C": Color(red: 0.26, green: 0.56, blue: 1.00),
    ]

    private var slices: [(name: String, pct: Double, color: Color)] {
        let total = Double(languages.values.reduce(0, +))
        guard total > 0 else { return [] }
        let sorted = languages.sorted { $0.value > $1.value }
        var top: [(String, Double, Color)] = []
        var otherBytes = 0.0
        for (idx, pair) in sorted.enumerated() {
            let pct = Double(pair.value) / total * 100.0
            if idx < 6 && pct >= 1.0 {
                top.append((pair.key, pct, Self.colorMap[pair.key] ?? HubTheme.accent))
            } else {
                otherBytes += Double(pair.value)
            }
        }
        if otherBytes > 0 {
            top.append(("Other", otherBytes / total * 100.0, Color.secondary.opacity(0.45)))
        }
        return top
    }

    var body: some View {
        let items = slices
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Languages 语言")
                    .font(.headline)

                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, s in
                            let w = max(4, (geo.size.width - CGFloat(items.count - 1) * 2) * CGFloat(s.pct / 100.0))
                            s.color.frame(width: w)
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, s in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(s.color)
                                .frame(width: 9, height: 9)
                            Text(s.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(String(format: "%.1f%%", s.pct))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .hubCard()
        }
    }
}

// MARK: - Rich WebKit Markdown + HTML + Math + <picture srcset> Renderer

struct RichMarkdownWebView: View {
    let markdown: String
    var owner: String? = nil
    var repo: String? = nil
    var branch: String? = nil

    @Environment(\.colorScheme) private var scheme
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        let html = MarkdownHTMLBuilder.buildDocument(
            markdown: markdown,
            owner: owner,
            repo: repo,
            branch: branch,
            isDark: scheme == .dark
        )
        MarkdownWebRepresentable(html: html, height: $contentHeight)
            .frame(height: max(60, contentHeight))
    }
}

private struct MarkdownWebRepresentable: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "heightChanged")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.navigationDelegate = context.coordinator
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: URL(string: "https://github.com"))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            web.loadHTMLString(html, baseURL: URL(string: "https://github.com"))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownWebRepresentable
        var lastHTML: String = ""

        init(_ parent: MarkdownWebRepresentable) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "heightChanged", let num = message.body as? NSNumber {
                let h = CGFloat(num.doubleValue)
                if h > 20, abs(h - parent.height) > 2 {
                    DispatchQueue.main.async {
                        self.parent.height = h
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Add Repo Sheet (Single & Batch with Multi-level Category Picker)

struct AddRepoSheet: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    var defaultCategoryId: Int64? = nil

    @State private var inputText = ""
    @State private var selectedCategoryId: Int64? = nil
    @State private var submitting = false
    @State private var errorMessages: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $inputText)
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("GitHub 仓库地址（支持批量，每行一个）")
                } footer: {
                    Text("支持 owner/repo、https://github.com/owner/repo、git@github.com:owner/repo.git。首次同步建立历史基线，不发送历史通知。")
                }

                Section("保存到分类（支持多级分类）") {
                    Picker("分类", selection: $selectedCategoryId) {
                        Text("未分类").tag(Int64?.none)
                        ForEach(app.categoryTree) { node in
                            Text(node.pickerLabel).tag(Optional(node.id))
                        }
                    }
                }

                if !errorMessages.isEmpty {
                    Section("解析提示") {
                        ForEach(errorMessages, id: \.self) { msg in
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("添加软件源")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let def = defaultCategoryId, def > 0 {
                    selectedCategoryId = def
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitting ? "添加中…" : "添加并同步") {
                        submit()
                    }
                    .disabled(submitting || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func submit() {
        submitting = true
        errorMessages = []
        Task {
            let res = await app.addRepositories(rawInput: inputText, categoryId: selectedCategoryId)
            submitting = false
            if res.errors.isEmpty {
                dismiss()
            } else {
                errorMessages = res.errors
                if res.added > 0 { inputText = "" }
            }
        }
    }
}

// MARK: - Multi-level Categories Management Sheet

struct CategoriesSheet: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newParentId: Int64? = nil
    @State private var editingNode: CategoryTreeNode?
    @State private var editName = ""
    @State private var editParentId: Int64? = nil

    var body: some View {
        NavigationStack {
            List {
                Section("新建多级分类") {
                    TextField("输入分类名称（例如：工具 / iOS）", text: $newName)
                    Picker("上级分类", selection: $newParentId) {
                        Text("无（作为顶层分类）").tag(Int64?.none)
                        ForEach(app.categoryTree) { node in
                            Text(node.pickerLabel).tag(Optional(node.id))
                        }
                    }
                    Button("创建分类") {
                        app.createCategory(name: newName, parentId: newParentId)
                        newName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .foregroundStyle(HubTheme.accent)
                }

                Section("快捷筛选") {
                    Button {
                        app.selectedCategoryId = nil
                        dismiss()
                    } label: {
                        HStack {
                            Label("全部软件源", systemImage: "tray.full")
                            Spacer()
                            Text("\(app.repos.count)").foregroundStyle(.secondary)
                            if app.selectedCategoryId == nil {
                                Image(systemName: "checkmark").foregroundStyle(HubTheme.accent)
                            }
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        app.selectedCategoryId = -1
                        dismiss()
                    } label: {
                        HStack {
                            Label("未分类", systemImage: "folder")
                            Spacer()
                            Text("\(app.repos.filter { $0.categoryId == nil }.count)").foregroundStyle(.secondary)
                            if app.selectedCategoryId == -1 {
                                Image(systemName: "checkmark").foregroundStyle(HubTheme.accent)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }

                if !app.categoryTree.isEmpty {
                    Section("多级分类目录（左滑编辑或删除）") {
                        ForEach(app.categoryTree) { node in
                            Button {
                                app.selectedCategoryId = node.id
                                dismiss()
                            } label: {
                                HStack {
                                    HStack(spacing: 6) {
                                        if node.depth > 0 {
                                            Text(String(repeating: "　", count: node.depth) + "└")
                                                .foregroundStyle(.secondary)
                                        }
                                        Image(systemName: node.childrenCount > 0 ? "folder.fill" : "folder")
                                            .foregroundStyle(HubTheme.accent)
                                        Text(node.name)
                                    }
                                    Spacer()
                                    Text("\(node.totalCount)").foregroundStyle(.secondary)
                                    if app.selectedCategoryId == node.id {
                                        Image(systemName: "checkmark").foregroundStyle(HubTheme.accent)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                            .swipeActions {
                                Button(role: .destructive) {
                                    app.deleteCategory(id: node.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    editingNode = node
                                    editName = node.name
                                    editParentId = node.parentId
                                } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("分类管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editingNode) { node in
                NavigationStack {
                    Form {
                        TextField("分类名称", text: $editName)
                        Picker("上级分类", selection: $editParentId) {
                            Text("无（顶层分类）").tag(Int64?.none)
                            let forbidden = CategoryTree.descendantIds(of: node.id, in: app.categoryTree)
                            ForEach(app.categoryTree.filter { !forbidden.contains($0.id) }) { cand in
                                Text(cand.pickerLabel).tag(Optional(cand.id))
                            }
                        }
                    }
                    .navigationTitle("编辑分类")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { editingNode = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                app.updateCategory(id: node.id, name: editName, parentId: editParentId)
                                editingNode = nil
                            }
                            .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Relative Time Formatter

enum DateFmt {
    static func relative(_ date: Date?) -> String {
        guard let date = date else { return "从未" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func shortDateTime(_ date: Date?) -> String {
        guard let date = date else { return "-" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}
