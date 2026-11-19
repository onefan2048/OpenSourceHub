import SwiftUI
import OpenSourceHubCore

struct NotificationsView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var unreadOnly = false

    private var items: [NotificationItem] {
        app.notifications.filter { !unreadOnly || $0.readAt == nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "bell.slash")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("暂无通知记录")
                                .font(.headline)
                            Text("首次同步仅建立历史基线不推送；后续检测到新 Release、Tag 或提交更新时会在此展示。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .hubCard(padding: 28)
                    } else {
                        ForEach(items) { item in
                            Button {
                                app.store.markNotificationRead(id: item.id)
                                app.reloadAll()
                                if let s = item.url, let url = URL(string: s) {
                                    openURL(url)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        if item.readAt == nil {
                                            Circle()
                                                .fill(HubTheme.accent)
                                                .frame(width: 8, height: 8)
                                        }
                                        Text(item.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Spacer()
                                        Text(item.channel.uppercased())
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(item.status == "failed" ? .red : HubTheme.accent)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background((item.status == "failed" ? Color.red : HubTheme.accent).opacity(0.12))
                                            .clipShape(Capsule())
                                    }

                                    if let body = item.body, !body.isEmpty {
                                        Text(body)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    if let err = item.error, !err.isEmpty {
                                        Text("发送失败: \(err)")
                                            .font(.caption2)
                                            .foregroundStyle(.red)
                                    }

                                    HStack {
                                        if let repoName = item.repoFullName {
                                            Text(repoName)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(DateFmt.shortDateTime(item.createdAt))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
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
}
