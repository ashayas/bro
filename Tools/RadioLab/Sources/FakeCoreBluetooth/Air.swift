import Foundation

/// The simulated airwaves. Enforces the rules real iOS punishes silently.
public final class Air {
    public static var shared = Air()

    public final class Device {
        public let id = UUID()
        public var background = false
        public internal(set) var powered = true
        public var authorized = true
        var centrals: [CBCentralManager] = []
        var peripherals: [CBPeripheralManager] = []
        var restoring: [String: [String: Any]] = [:]
        var retired: [String: AnyObject] = [:]
    }

    final class Connection {
        var central: CBCentralManager
        let peripheral: CBPeripheral
        var host: CBPeripheralManager
        let remote: CBCentral

        init(central: CBCentralManager, peripheral: CBPeripheral, host: CBPeripheralManager, remote: CBCentral) {
            self.central = central
            self.peripheral = peripheral
            self.host = host
            self.remote = remote
        }
    }

    /// The device whose managers are being created.
    public var current: Device?
    public var mtu = 185
    /// Notifications accepted before `updateValue` starts returning false.
    public var notifyBuffer = 6
    public private(set) var violations: [String] = []
    public private(set) var backpressureEvents = 0
    public private(set) var writes = 0

    var devices: [Device] = []
    var connections: [Connection] = []
    var blockedPairs = Set<Set<UUID>>()
    var pendingConnects: [(CBCentralManager, CBPeripheral)] = []
    private var timer: Timer?
    private var closed = false

    public init() {}

    public func device() -> Device {
        let device = Device()
        devices.append(device)
        if timer == nil {
            timer = .scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.beat() }
        }
        return device
    }

    public func close() {
        closed = true
        timer?.invalidate()
    }

    func later(_ work: @escaping () -> Void) {
        DispatchQueue.main.async { if !self.closed { work() } }
    }

    func violate(_ text: String) { violations.append(text) }
    func countBackpressure() { backpressureEvents += 1 }
    func countWrite() { writes += 1 }

    public func setInRange(_ a: Device, _ b: Device, _ inRange: Bool) {
        if inRange {
            blockedPairs.remove([a.id, b.id])
            return
        }
        blockedPairs.insert([a.id, b.id])
        for link in connections where Set([link.central.device.id, link.host.device.id]) == [a.id, b.id] {
            drop(link)
        }
    }

    public func setPower(_ device: Device, on: Bool) {
        device.powered = on
        if !on {
            connections.filter { $0.central.device === device || $0.host.device === device }.forEach(drop)
            device.peripherals.forEach { $0.reset() }
            device.centrals.forEach { $0.reset() }
            pendingConnects.removeAll { $0.0.device === device }
        }
        device.centrals.forEach { manager in later { manager.delegate?.centralManagerDidUpdateState(manager) } }
        device.peripherals.forEach { manager in later { manager.delegate?.peripheralManagerDidUpdateState(manager) } }
    }

    /// The app quits while the phone stays connected.
    public func killApp(_ device: Device) {
        for link in connections where link.host.device === device {
            let services = link.peripheral.services ?? []
            let peripheral = link.peripheral
            later { peripheral.delegate?.peripheral(peripheral, didModifyServices: services) }
        }
        connections.filter { $0.central.device === device }.forEach(drop)
        device.centrals.forEach { $0.delegate = nil; $0.reset() }
        device.peripherals.forEach { $0.delegate = nil; $0.reset() }
        device.centrals.removeAll()
        device.peripherals.removeAll()
        pendingConnects.removeAll { $0.0.device === device }
    }

    /// iOS evicts the app but keeps its radio state for the next launch.
    public func evictForRestoration(_ device: Device) {
        for manager in device.centrals {
            manager.delegate = nil
            guard let id = manager.restoreID else { continue }
            let held = connections.filter { $0.central === manager }.map(\.peripheral)
            device.restoring[id] = [CBCentralManagerRestoredStatePeripheralsKey: held]
            device.retired[id] = manager
        }
        for manager in device.peripherals {
            manager.delegate = nil
            guard let id = manager.restoreID else { continue }
            device.restoring[id] = [CBPeripheralManagerRestoredStateServicesKey: manager.services]
            device.retired[id] = manager
        }
        device.centrals.removeAll()
        device.peripherals.removeAll()
    }

    func canHear(_ a: Device, _ b: Device) -> Bool {
        a !== b && a.powered && b.powered && !blockedPairs.contains([a.id, b.id])
    }

    func connection(for peripheral: CBPeripheral) -> Connection? {
        connections.first { $0.peripheral === peripheral }
    }

    func drop(_ link: Connection) {
        guard let index = connections.firstIndex(where: { $0 === link }) else { return }
        connections.remove(at: index)
        link.peripheral.state = .disconnected
        for characteristic in link.peripheral.services?.flatMap({ $0.characteristics ?? [] }) ?? [] {
            characteristic.isNotifying = false
        }
        link.host.unsubscribe(link.remote)
        let manager = link.central, peripheral = link.peripheral
        later { manager.delegate?.centralManager(manager, didDisconnectPeripheral: peripheral, error: nil) }
    }

    private func beat() {
        for (manager, peripheral) in pendingConnects {
            guard let host = peripheral.device.peripherals.first, canHear(manager.device, peripheral.device),
                  host.advertising != nil || !host.services.isEmpty else { continue }
            pendingConnects.removeAll { $0.1 === peripheral }
            peripheral.state = .connected
            connections.append(Connection(
                central: manager, peripheral: peripheral, host: host, remote: host.remote(manager.device)
            ))
            later { manager.delegate?.centralManager(manager, didConnect: peripheral) }
        }

        for scannerDevice in devices where scannerDevice.powered {
            for manager in scannerDevice.centrals where manager.scanning {
                // iOS delivers nothing for an unfiltered background scan.
                if scannerDevice.background && manager.filter == nil { continue }
                for advertiser in devices where canHear(scannerDevice, advertiser) {
                    for host in advertiser.peripherals {
                        guard let uuids = host.advertising else { continue }
                        if advertiser.background {
                            // Overflow area: explicit scans only, and not with both sides asleep.
                            guard manager.filter != nil, !scannerDevice.background else { continue }
                        }
                        if let filter = manager.filter, !uuids.contains(where: filter.contains) { continue }
                        guard manager.duplicates || manager.reported.insert(advertiser.id).inserted else { continue }
                        let peripheral = manager.peripheral(advertiser)
                        manager.delegate?.centralManager(
                            manager, didDiscover: peripheral,
                            advertisementData: [CBAdvertisementDataServiceUUIDsKey: uuids], rssi: -50
                        )
                    }
                }
            }
        }
        for device in devices { device.peripherals.forEach { $0.drain() } }
    }
}
