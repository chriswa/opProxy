import SwiftUI
import UserNotifications

@main
struct OpProxyPhoneApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = FeedModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    delegate.model = model
                    #if DEBUG
                    if let shot = Screenshot.current { model.prepare(shot) }
                    #endif
                }
                .onChange(of: phase, initial: true) { _, phase in model.setActive(phase == .active) }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: FeedModel?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        #if DEBUG
        // Screenshots skip the permission prompt, which would cover them.
        let screenshot = Screenshot.current != nil
        #else
        let screenshot = false
        #endif
        if !screenshot { center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive]) { _, _ in } }
        application.registerForRemoteNotifications()
        return true
    }

    /// With the app open, the request is already on screen: fetch it, and show nothing.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        await model?.refresh()
        return []
    }

    /// Requests are answered oldest first, so a tapped notification just opens the queue.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await model?.refresh()
    }
}
