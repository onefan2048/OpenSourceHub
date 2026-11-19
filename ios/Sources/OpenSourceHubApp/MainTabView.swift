import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var app: AppStore

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $app.selectedTab) {
                ReposView()
                    .tabItem {
                        Label("软件源", systemImage: "shippingbox.fill")
                    }
                    .tag(0)

                DiscoverView()
                    .tabItem {
                        Label("发现", systemImage: "safari.fill")
                    }
                    .tag(1)

                NotificationsView()
                    .tabItem {
                        Label("通知", systemImage: "bell.fill")
                    }
                    .badge(app.stats.unreadNotifications)
                    .tag(2)

                SettingsView()
                    .tabItem {
                        Label("设置", systemImage: "gearshape.fill")
                    }
                    .tag(3)
            }
            .tint(HubTheme.accent)

            if let toast = app.toastMessage {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.82), in: Capsule())
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: app.toastMessage)
    }
}
