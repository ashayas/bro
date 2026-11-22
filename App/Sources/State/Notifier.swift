import BroKit
import UIKit
import UserNotifications

/// Local notifications for bros that arrive over Bluetooth while you're in your pocket.
struct Notifier {
    private static let channelKey = "channel"
    private var center: UNUserNotificationCenter { .current() }

    func requestPermission() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-noNotificationPrompt") { return }
        #endif
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ bro: Bro, title: String, badge: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = bro.mood.map { "\($0.emoji) \($0.line)" } ?? bro.line
        content.sound = UNNotificationSound(named: UNNotificationSoundName("receive.wav"))
        content.badge = NSNumber(value: badge)
        if let data = try? JSONEncoder().encode(bro.channel) {
            content.userInfo = [Self.channelKey: data]
        }
        if let mood = bro.mood, let attachment = sticker(mood) { content.attachments = [attachment] }
        center.add(UNNotificationRequest(identifier: bro.id, content: content, trigger: nil))
    }

    func clear() {
        center.removeAllDeliveredNotifications()
        UIApplication.shared.applicationIconBadgeNumber = 0
    }

    static func channel(from info: [AnyHashable: Any]) -> Channel? {
        guard let data = info[channelKey] as? Data else { return nil }
        return try? JSONDecoder().decode(Channel.self, from: data)
    }

    private func sticker(_ mood: Mood) -> UNNotificationAttachment? {
        guard let png = UIImage(named: mood.asset)?.pngData() else { return nil }
        // iOS moves the file away, so each notification gets its own.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: mood.slug, url: url)
    }
}
