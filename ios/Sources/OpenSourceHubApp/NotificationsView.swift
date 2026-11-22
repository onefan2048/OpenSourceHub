import SwiftUI
import OpenSourceHubCore

/// Merged notification group representing one project version update across all delivery channels.
private struct MergedNotificationGroup: Identifiable {
    let id: String
    let ids: [Int64]
    let repositoryId: Int64
    let repoFullName: String?
    let title: String
    let body: String?
    let url: String?
    let createdAt: Date
    let isUnread: Bool
    let channels: [(channel: String, status: String, error: String?)]
}

struct NotificationsView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    enum SectionFilter: String, CaseIterable {
        case all = "全部板块"
        case account = "我的回复"
        case repo = "软件源更新"
    }

    @State private var sectionFilter: SectionFilter = .all
    @State private var selectedAccountId: Int64? = nil // nil = all accounts
    @State private var selectedKind: String = "all" // all | issue | discussion
    @State private var unreadOnly = false

    private var filteredAccountReplies: [AccountNotificationItem] {
        app.accountNotifications.filter { item in
            if let aid = selectedAccountId, item.accountId != aid { return false }
            if selectedKind != "all" && item.kind != selectedKind { return false }
            if unreadOnly && item.readAt != nil { return false }
            return true
        }
    }

    private var groupedRepoNotifs: [MergedNotificationGroup] {
        var order: [String] = []
        var buckets: [String: [NotificationItem]] = [:]

        for item in app.notifications {
            let key: String
            if let evId = item.versionEventId {
                key = "ev:\(item.repositoryId):\(evId)"
            } else {
                let minute = Int(item.createdAt.timeIntervalSince1970 / 60)
                key = "msg:\(item.repositoryId):\(item.title):\(minute)"
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }

        let merged: [MergedNotificationGroup] = order.compactMap { key in
            guard let list = buckets[key], let first = list.first else { return nil }
            let unread = list.contains(where: { $0.readAt == nil })
            let channels = list.map { (channel: $0.channel, status: $0.status, error: $0.error) }
            return MergedNotificationGroup(
                id: key,
                ids: list.map(\.id),
                repositoryId: first.repositoryId,
                repoFullName: first.repoFullName,
                title: first.title,
                body: first.body,
                url: first.url,
                createdAt: list.map(\.createdAt).max() ?? first.createdAt,
                isUnread: unread,
                channels: channels
            )
        }

        return merged.filter { !unreadOnly || $0.isUnread }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // Section Filter Bar (Matches Docker Notification Center)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            sectionChip(.all, title: "全部板块 (未读 \(app.stats.totalUnread))")
                            sectionChip(.account, title: "我的 Issue & Discussion 回复 (\(app.stats.unreadAccountNotifications))")
                            sectionChip(.repo, title: "软件源更新通知 (\(app.stats.unreadNotifications))")
                        }
                    }

                    // Multi-account & kind filter bar when showing account replies
                    if sectionFilter != .repo {
                        accountFilterBar
                    }

                    // 1. Account Issue & Discussion Replies Section
                    if sectionFilter == .all || sectionFilter == .account {
                        accountRepliesSection
                    }

                    // 2. Repository Version Update Notifications Section
                    if sectionFilter == .all || sectionFilter == .repo {
                        repoUpdatesSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(HubTheme.canvas(scheme).ignoresSafeArea())
            .navigationTitle("通知中心")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(unreadOnly ? "显示全部" : "仅看未读") {
                        unreadOnly.toggle()
                    }
                    .font(.subheadline)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await app.syncAccountReplies(accountId: selectedAccountId) }
                    } label: {
                        if app.isSyncingAccounts {
                            ProgressView().tint(HubTheme.accent)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(app.isSyncingAccounts)

                    Button("全部已读") {
                        app.markAllNotificationsRead()
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private func sectionChip(_ sec: SectionFilter, title: String) -> some View {
        Button {
            sectionFilter = sec
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(sectionFilter == sec ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(sectionFilter == sec ? HubTheme.accent : HubTheme.card(scheme))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var accountFilterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("账号:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    miniChip(title: "全部账号 (\(app.githubAccounts.count))", active: selectedAccountId == nil) {
                        selectedAccountId = nil
                    }
                    ForEach(app.githubAccounts) { acc in
                        miniChip(title: "@\(acc.login)", active: selectedAccountId == acc.id) {
                            selectedAccountId = acc.id
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Text("类型:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                miniChip(title: "全部", active: selectedKind == "all") { selectedKind = "all" }
                miniChip(title: "Issues", active: selectedKind == "issue") { selectedKind = "issue" }
                miniChip(title: "Discussions", active: selectedKind == "discussion") { selectedKind = "discussion" }
                Spacer()
                NavigationLink {
                    GitHubAccountsManageView()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "person.badge.plus")
                        Text("管理账号 (\(app.githubAccounts.count))")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HubTheme.accent)
                }
            }
        }
        .hubCard(padding: 12, radius: 16)
    }

    private func miniChip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
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

    // MARK: - Account Replies Section

    private var accountRepliesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("我的 Issue & Discussion 回复", systemImage: "bubble.left.and.bubble.right")
                    .font(.subheadline.weight(.bold))
                Text("未读 \(app.stats.unreadAccountNotifications) · 显示 \(filteredAccountReplies.count) 条")
                    .font(.caption2)
                    .foregroundStyle(HubTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(HubTheme.accentSoft)
                    .clipShape(Capsule())
                Spacer()
                if app.stats.unreadAccountNotifications > 0 {
                    Button("本板块已读") {
                        app.markAllAccountNotificationsRead(accountId: selectedAccountId)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HubTheme.accent)
                }
            }

            if app.githubAccounts.isEmpty {
                VStack(spacing: 8) {
                    Text("尚未登录 GitHub 账号")
                        .font(.subheadline.weight(.semibold))
                    Text("在「管理账号」或设置页添加你的 GitHub Personal Access Token 后，会自动追踪你发起的 Issue / Discussion 收到的他人回复。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .hubCard(padding: 20)
            } else if filteredAccountReplies.isEmpty {
                Text("暂无匹配的 Issue / Discussion 回复通知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .hubCard(padding: 20)
            } else {
                ForEach(filteredAccountReplies) { item in
                    accountReplyCard(item)
                }
            }
        }
    }

    private func accountReplyCard(_ item: AccountNotificationItem) -> some View {
        let subscribedRepo = app.repos.first(where: { $0.fullNameKey == item.repoFullName.lowercased() })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if item.readAt == nil {
                    Circle().fill(HubTheme.accent).frame(width: 8, height: 8)
                }
                Text("\(item.repoFullName) #\(item.number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.kind == "discussion" ? "Discussion" : "Issue")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                if let login = item.accountLogin {
                    Text("@\(login)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(HubTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HubTheme.accentSoft)
                        .clipShape(Capsule())
                }
                Spacer()
                Text(DateFmt.relative(item.occurredAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                app.markAccountNotificationRead(id: item.id)
                if let u = URL(string: item.url) { openURL(u) }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    HStack(alignment: .top, spacing: 5) {
                        if item.reason == "answer" {
                            Text("已采纳答案")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(HubTheme.accent)
                                .clipShape(Capsule())
                        }
                        if let actor = item.actorLogin {
                            Text("@\(actor) 回复：")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        Text(item.body ?? "收到新的互动或回复")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            HStack {
                Spacer()
                if let sub = subscribedRepo {
                    NavigationLink {
                        RepoDetailView(repoId: sub.id)
                    } label: {
                        Text("项目页")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(HubTheme.accent)
                    }
                }
                if let u = URL(string: item.url) {
                    Button {
                        app.markAccountNotificationRead(id: item.id)
                        openURL(u)
                    } label: {
                        HStack(spacing: 2) {
                            Text("GitHub")
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .hubCard(padding: 13, radius: 18)
    }

    // MARK: - Repository Version Updates Section

    private var repoUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("软件源版本更新通知", systemImage: "shippingbox")
                    .font(.subheadline.weight(.bold))
                Spacer()
                if !app.notifications.isEmpty {
                    Button(role: .destructive) {
                        app.clearNotifications()
                    } label: {
                        Label("清空", systemImage: "trash")
                            .font(.caption)
                    }
                }
            }
            .padding(.top, 4)

            if groupedRepoNotifs.isEmpty {
                VStack(spacing: 8) {
                    Text("暂无软件源版本更新通知")
                        .font(.subheadline.weight(.semibold))
                    Text("仅显示首次基线建立之后发现的更新。同一项目的不同通知渠道会自动合并展示。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .hubCard(padding: 22)
            } else {
                ForEach(groupedRepoNotifs) { group in
                    Button {
                        app.markNotificationsRead(ids: group.ids)
                        if let s = group.url, let url = URL(string: s) {
                            openURL(url)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 6) {
                                if group.isUnread {
                                    Circle()
                                        .fill(HubTheme.accent)
                                        .frame(width: 8, height: 8)
                                        .padding(.top, 5)
                                }
                                Text(group.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Text(DateFmt.shortDateTime(group.createdAt))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            if let body = group.body, !body.isEmpty {
                                Text(body)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(Array(group.channels.enumerated()), id: \.offset) { _, ch in
                                        channelBadge(ch.channel, status: ch.status)
                                    }
                                }
                            }

                            let failedErrors = group.channels.filter { $0.status == "failed" && ($0.error?.isEmpty == false) }
                            ForEach(Array(failedErrors.enumerated()), id: \.offset) { _, f in
                                Text("\(channelLabel(f.channel)) 发送失败: \(f.error ?? "")")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }

                            if let repoName = group.repoFullName {
                                Text(repoName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .hubCard(padding: 14, radius: 18)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func channelLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "web": return "站内"
        case "email": return "EMAIL"
        case "qq": return "QQ"
        case "feishu": return "FEISHU"
        case "wecom": return "WECOM"
        case "discord": return "DISCORD"
        case "telegram": return "TELEGRAM"
        case "webhook": return "WEBHOOK"
        default: return raw.uppercased()
        }
    }

    private func channelBadge(_ channel: String, status: String) -> some View {
        let failed = status == "failed"
        let color: Color = failed ? .red : HubTheme.accent
        return HStack(spacing: 3) {
            Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 9))
            Text(channelLabel(channel))
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}
