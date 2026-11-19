import SwiftUI
import BackgroundTasks
import OpenSourceHubCore

@main
struct OpenSourceHubApp: App {
    @StateObject private var appStore = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    static let bgTaskId = "com.opensourcehub.ios.refresh"

    init() {
        AppStore.requestNotificationPermission()
        registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appStore)
                .tint(HubTheme.accent)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                scheduleBackgroundRefresh()
            } else if newPhase == .active {
                appStore.reloadAll()
            }
        }
    }

    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskId, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            scheduleBackgroundRefresh()
            let work = Task {
                await appStore.syncAll(onlyDue: true)
                refreshTask.setTaskCompleted(success: true)
            }
            refreshTask.expirationHandler = {
                work.cancel()
                refreshTask.setTaskCompleted(success: false)
            }
        }
    }

    private func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.bgTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
}
