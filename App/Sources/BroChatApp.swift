import SwiftUI
import UIKit
import UserNotifications

@main
struct BroChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(delegate.store)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    // Owned here, not by a view: when Bluetooth relaunches us in the background there may be no views.
    private(set) lazy var store = BroStore()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        store.launch()
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // In use, the app shows its own banner. Mid-swipe to the home screen, let iOS show it.
        completionHandler(UIApplication.shared.applicationState == .active ? [] : [.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let channel = Notifier.channel(from: response.notification.request.content.userInfo)
        DispatchQueue.main.async {
            if let channel { self.store.show(channel) }
            completionHandler()
        }
    }
}
