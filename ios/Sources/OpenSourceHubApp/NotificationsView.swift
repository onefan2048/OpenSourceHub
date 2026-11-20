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
    @State private var unreadOnly = false

    private var groupedItems: [MergedNotificationGroup] {
        var order: [String] = []
        var buckets: [String: [NotificationItem]] = [:]

        for item in app.notifications {
            let key: String
            if let evId = item.versionEventId {
                key = "ev:\(item.repositoryId):\(evId)"
            } else {
                // Fallback grouping by repo + title within same minute
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
                LazyVStack(spacing: 12) {
                    if groupedItems.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "bell.slash")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("暂无通知记录")
                                .font(.headline)
                            Text("仅显示首次基线建立之后发现的更新。同一项目的不同通知渠道会自动合并展示。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .hubCard(padding: 28)
                    } else {
                        ForEach(groupedItems) { group in
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

                                    // Merged channel badges row
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(Array(group.channels.enumerated()), id: \.offset) { _, ch in
                                                channelBadge(ch.channel, status: ch.status)
                                            }
                                        }
                                    }

                                    // Show any failed channel error inline
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
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(HubTheme.canvas(scheme).ignoresSafeArea())
            .navigationTitle("通知")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(unreadOnly ? "显示全部" : "仅看未读") {
                        unreadOnly.toggle()
                    }
                    .font(.subheadline)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !app.notifications.isEmpty {
                        Button("全部已读") {
                            app.markAllNotificationsRead()
                        }
                        .font(.subheadline)
                        Button(role: .destructive) {
                            app.clearNotifications()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
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
