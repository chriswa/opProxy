import SwiftUI
import UserNotifications

@main
struct OpProxyPhoneApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(delegate.model)
                .onAppear {
                    #if DEBUG
                    if let shot = Screenshot.current { delegate.model.prepare(shot) }
                    // `-pair <code>`: pairs as if the code were scanned, for testing from a Mac
                    // with `devicectl device process launch`. Progress goes to the console.
                    let arguments = ProcessInfo.processInfo.arguments
                    if let i = arguments.firstIndex(of: "-pair"), i + 1 < arguments.count {
                        Task {
                            let failure = await delegate.model.pair(qr: arguments[i + 1]) { print("pairing: \($0)") }
                            print(failure.map { "pairing failed: \($0)" } ?? "paired")
                        }
                    }
                    #endif
                }
                .onChange(of: phase, initial: true) { _, phase in delegate.model.setActive(phase == .active) }
        }
    }
}

/// Owns the model, since a silent push can launch the app in the background without its UI.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = FeedModel()

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
        await model.refresh()
        return []
    }

    /// A silent push: the Mac answered or deleted a request. Fetching takes down its notification.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        await model.refresh()
        return .newData
    }

    /// Requests are answered oldest first, so a tapped notification just opens the queue.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await model.refresh()
    }
}
