import BroKit
import UIKit

/// Decides when each radio runs. Bluetooth works in the background, Wi-Fi sockets don't.
final class Radios {
    let ble = BLETransport(restorationID: "com.ashayas.brochat.radio")
    let lan = LANTransport()

    var onChange: (() -> Void)?

    private var bluetoothEnabled = false
    private var wifiEnabled = false
    private var active = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var suspendLAN: Timer?

    init() {
        ble.setForeground(false)
        ble.onStatus = { [weak self] _ in self?.onChange?() }
        lan.onStatus = { [weak self] _ in self?.onChange?() }
    }

    func configure(bluetooth: Bool, wifi: Bool) {
        bluetoothEnabled = bluetooth
        wifiEnabled = wifi
        if bluetooth { ble.start() } else { ble.stop() }
        if !wifi {
            lan.stop()
        } else if active {
            lan.start()
        }
    }

    func becameActive() {
        active = true
        endGracePeriod()
        ble.setForeground(true)
        if wifiEnabled { lan.start() }
    }

    func enteredBackground() {
        active = false
        ble.setForeground(false)
        guard wifiEnabled else { return }
        // A short grace period for app switching, then close sockets before iOS breaks them.
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.lan.stop()
            self?.endGracePeriod()
        }
        suspendLAN = .scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.lan.stop()
            self?.endGracePeriod()
        }
    }

    private func endGracePeriod() {
        suspendLAN?.invalidate()
        suspendLAN = nil
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
