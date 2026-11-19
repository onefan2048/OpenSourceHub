import SwiftUI
import UIKit
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

// MARK: - Add Repo Sheet (Single & Batch)

struct AddRepoSheet: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
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
                    Text("支持 owner/repo、https://github.com/owner/repo、git@github.com:owner/repo.git")
                }

                if !app.categories.isEmpty {
                    Section("所属分类（可选）") {
                        Picker("分类", selection: $selectedCategoryId) {
                            Text("未分类").tag(Int64?.none)
                            ForEach(app.categories) { cat in
                                Text(cat.name).tag(Optional(cat.id))
                            }
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
                if res.added > 0 {
                    inputText = ""
                }
            }
        }
    }
}

// MARK: - Categories Management Sheet

struct CategoriesSheet: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var editingCat: CategoryItem?
    @State private var editName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("新建分类") {
                    HStack {
                        TextField("输入分类名称", text: $newName)
                        Button("添加") {
                            app.createCategory(name: newName)
                            newName = ""
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .foregroundStyle(HubTheme.accent)
                    }
                }

                Section("全部软件源") {
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

                if !app.categories.isEmpty {
                    Section("自定义分类") {
                        ForEach(app.categories) { cat in
                            Button {
                                app.selectedCategoryId = cat.id
                                dismiss()
                            } label: {
                                HStack {
                                    Label(cat.name, systemImage: "folder.fill")
                                        .foregroundStyle(HubTheme.accent)
                                    Spacer()
                                    Text("\(cat.repoCount)").foregroundStyle(.secondary)
                                    if app.selectedCategoryId == cat.id {
                                        Image(systemName: "checkmark").foregroundStyle(HubTheme.accent)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                            .swipeActions {
                                Button(role: .destructive) {
                                    app.deleteCategory(id: cat.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    editingCat = cat
                                    editName = cat.name
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("分类与筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("重命名分类", isPresented: Binding(get: { editingCat != nil }, set: { if !$0 { editingCat = nil } })) {
                TextField("分类名称", text: $editName)
                Button("保存") {
                    if let c = editingCat { app.renameCategory(id: c.id, name: editName) }
                    editingCat = nil
                }
                Button("取消", role: .cancel) { editingCat = nil }
            }
        }
    }
}

// MARK: - Lightweight Native Markdown Renderer (0 external dependencies!)

struct MarkdownBlockView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: "\n").prefix(250).enumerated()), id: \.offset) { _, line in
                renderLine(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderLine(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed.hasPrefix("### ") {
            Text(trimmed.dropFirst(4))
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
        } else if trimmed.hasPrefix("## ") {
            Text(trimmed.dropFirst(3))
                .font(.headline)
                .padding(.top, 6)
        } else if trimmed.hasPrefix("# ") {
            Text(trimmed.dropFirst(2))
                .font(.title3.bold())
                .padding(.top, 8)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(HubTheme.accent)
                inlineMarkdown(String(trimmed.dropFirst(2)))
            }
            .font(.subheadline)
        } else {
            inlineMarkdown(raw)
                .font(.subheadline)
        }
    }

    private func inlineMarkdown(_ text: String) -> Text {
        if let attr = try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(text)
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
