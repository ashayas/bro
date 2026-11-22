import Foundation

// The slice of CoreBluetooth's API that BLETransport uses.

public let CBCentralManagerOptionShowPowerAlertKey = "c.alert"
public let CBPeripheralManagerOptionShowPowerAlertKey = "p.alert"
public let CBCentralManagerOptionRestoreIdentifierKey = "c.restore"
public let CBPeripheralManagerOptionRestoreIdentifierKey = "p.restore"
public let CBCentralManagerRestoredStatePeripheralsKey = "c.peripherals"
public let CBPeripheralManagerRestoredStateServicesKey = "p.services"
public let CBCentralManagerScanOptionAllowDuplicatesKey = "duplicates"
public let CBAdvertisementDataServiceUUIDsKey = "uuids"

public enum CBManagerState { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
public enum CBPeripheralState { case disconnected, connecting, connected, disconnecting }
public enum CBCharacteristicWriteType { case withResponse, withoutResponse }

public struct CBATTError: Error {
    public enum Code { case success, invalidOffset }
}

public struct CBCharacteristicProperties: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let write = Self(rawValue: 1), notify = Self(rawValue: 2)
}

public struct CBAttributePermissions: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let writeable = Self(rawValue: 1)
}

public final class CBUUID: NSObject {
    public let data: Data

    public init(data: Data) { self.data = data }
    public init(string: String) { data = withUnsafeBytes(of: UUID(uuidString: string)!.uuid) { Data($0) } }

    override public func isEqual(_ object: Any?) -> Bool { (object as? CBUUID)?.data == data }
    override public var hash: Int { data.hashValue }
}

public class CBService: NSObject {
    public let uuid: CBUUID
    public var characteristics: [CBCharacteristic]?
    init(uuid: CBUUID) { self.uuid = uuid }
}

public final class CBMutableService: CBService {
    public init(type: CBUUID, primary: Bool) { super.init(uuid: type) }
}

public class CBCharacteristic: NSObject {
    public let uuid: CBUUID
    public var value: Data?
    public internal(set) var isNotifying = false
    init(uuid: CBUUID) { self.uuid = uuid }
}

public final class CBMutableCharacteristic: CBCharacteristic {
    public internal(set) var subscribedCentrals: [CBCentral]?

    public init(type: CBUUID, properties: CBCharacteristicProperties, value: Data?, permissions: CBAttributePermissions) {
        super.init(uuid: type)
    }
}

public final class CBCentral: NSObject {
    public let identifier = UUID()
    public var maximumUpdateValueLength: Int { Air.shared.mtu - 3 }
}

public final class CBATTRequest: NSObject {
    public let central: CBCentral
    public let characteristic: CBCharacteristic
    public var value: Data?
    public var offset = 0
    let answer: () -> Void

    init(central: CBCentral, characteristic: CBCharacteristic, value: Data, answer: @escaping () -> Void) {
        self.central = central
        self.characteristic = characteristic
        self.value = value
        self.answer = answer
    }
}

public protocol CBCentralManagerDelegate: AnyObject {
    func centralManagerDidUpdateState(_ manager: CBCentralManager)
    func centralManager(_ manager: CBCentralManager, willRestoreState dict: [String: Any])
    func centralManager(_ manager: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber)
    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral)
    func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?)
    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?)
}

public protocol CBPeripheralDelegate: AnyObject {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService])
}

public protocol CBPeripheralManagerDelegate: AnyObject {
    func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager)
    func peripheralManager(_ manager: CBPeripheralManager, willRestoreState dict: [String: Any])
    func peripheralManager(_ manager: CBPeripheralManager, didAdd service: CBService, error: Error?)
    func peripheralManager(_ manager: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic)
    func peripheralManager(_ manager: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic)
    func peripheralManager(_ manager: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest])
    func peripheralManagerIsReady(toUpdateSubscribers manager: CBPeripheralManager)
}

public final class CBCentralManager: NSObject {
    public weak var delegate: CBCentralManagerDelegate?
    let device: Air.Device
    let restoreID: String?
    var scanning = false
    var filter: [CBUUID]?
    var duplicates = false
    var reported = Set<UUID>()
    var known: [UUID: CBPeripheral] = [:]

    public init(delegate: CBCentralManagerDelegate?, queue: DispatchQueue?, options: [String: Any]? = nil) {
        device = Air.shared.current!
        restoreID = options?[CBCentralManagerOptionRestoreIdentifierKey] as? String
        self.delegate = delegate
        super.init()
        device.centrals.append(self)
        var restored: [String: Any]?
        if let id = restoreID, let old = device.retired.removeValue(forKey: id) as? CBCentralManager {
            restored = device.restoring.removeValue(forKey: id)
            known = old.known
            for link in Air.shared.connections where link.central === old { link.central = self }
        }
        Air.shared.later {
            if let restored { self.delegate?.centralManager(self, willRestoreState: restored) }
            self.delegate?.centralManagerDidUpdateState(self)
        }
    }

    public var state: CBManagerState {
        !device.authorized ? .unauthorized : device.powered ? .poweredOn : .poweredOff
    }

    func requireOn(_ call: String) -> Bool {
        if state == .poweredOn { return true }
        Air.shared.violate("\(call) while not powered on")
        return false
    }

    func reset() {
        scanning = false
        reported.removeAll()
    }

    func peripheral(_ remote: Air.Device) -> CBPeripheral {
        if let existing = known[remote.id] { return existing }
        let made = CBPeripheral(device: remote)
        known[remote.id] = made
        return made
    }

    public func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?) {
        guard requireOn("scan") else { return }
        scanning = true
        filter = services
        duplicates = options?[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool ?? false
        reported.removeAll()
    }

    public func stopScan() {
        guard requireOn("stopScan") else { return }
        scanning = false
    }

    public func connect(_ peripheral: CBPeripheral, options: [String: Any]?) {
        guard requireOn("connect"), peripheral.state != .connected else { return }
        peripheral.state = .connecting
        Air.shared.pendingConnects.removeAll { $0.1 === peripheral }
        Air.shared.pendingConnects.append((self, peripheral))
    }

    public func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        guard requireOn("cancel") else { return }
        Air.shared.pendingConnects.removeAll { $0.1 === peripheral }
        if let link = Air.shared.connection(for: peripheral) {
            Air.shared.drop(link)
        } else {
            peripheral.state = .disconnected
        }
    }
}

public final class CBPeripheral: NSObject {
    public let identifier = UUID()
    public weak var delegate: CBPeripheralDelegate?
    public internal(set) var state: CBPeripheralState = .disconnected
    public internal(set) var services: [CBService]?
    let device: Air.Device

    init(device: Air.Device) { self.device = device }

    private func connection(_ call: String) -> Air.Connection? {
        let link = Air.shared.connection(for: self)
        if link == nil { Air.shared.violate("\(call) while disconnected") }
        return link
    }

    public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { Air.shared.mtu - 3 }

    public func discoverServices(_ uuids: [CBUUID]?) {
        guard let link = connection("discoverServices") else { return }
        Air.shared.later {
            self.services = link.host.services.map { hosted in
                let copy = CBService(uuid: hosted.uuid)
                copy.characteristics = hosted.characteristics?.map { original in
                    let mine = CBCharacteristic(uuid: original.uuid)
                    mine.isNotifying = (original as? CBMutableCharacteristic)?
                        .subscribedCentrals?.contains(link.remote) ?? false
                    return mine
                }
                return copy
            }
            self.delegate?.peripheral(self, didDiscoverServices: nil)
        }
    }

    public func discoverCharacteristics(_ uuids: [CBUUID]?, for service: CBService) {
        guard connection("discoverCharacteristics") != nil else { return }
        Air.shared.later { self.delegate?.peripheral(self, didDiscoverCharacteristicsFor: service, error: nil) }
    }

    public func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        guard let link = connection("setNotify") else { return }
        Air.shared.later {
            guard let hosted = link.host.characteristic(characteristic.uuid) else { return }
            characteristic.isNotifying = enabled
            hosted.subscribedCentrals = (hosted.subscribedCentrals ?? []) + [link.remote]
            link.host.delegate?.peripheralManager(link.host, central: link.remote, didSubscribeTo: hosted)
            self.delegate?.peripheral(self, didUpdateNotificationStateFor: characteristic, error: nil)
        }
    }

    public func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        guard let link = connection("write") else { return }
        if data.count > Air.shared.mtu - 3 { Air.shared.violate("write over MTU") }
        Air.shared.countWrite()
        Air.shared.later {
            guard let hosted = link.host.characteristic(characteristic.uuid) else { return }
            let request = CBATTRequest(central: link.remote, characteristic: hosted, value: data) {
                Air.shared.later { self.delegate?.peripheral(self, didWriteValueFor: characteristic, error: nil) }
            }
            link.host.delegate?.peripheralManager(link.host, didReceiveWrite: [request])
        }
    }
}

public final class CBPeripheralManager: NSObject {
    public weak var delegate: CBPeripheralManagerDelegate?
    let device: Air.Device
    let restoreID: String?
    var services: [CBMutableService] = []
    var advertising: [CBUUID]?
    public var isAdvertising: Bool { advertising != nil }
    private var remotes: [UUID: CBCentral] = [:]
    private var buffer: [(value: Data, uuid: CBUUID, centrals: [CBCentral])] = []
    private var wasFull = false

    public init(delegate: CBPeripheralManagerDelegate?, queue: DispatchQueue?, options: [String: Any]? = nil) {
        device = Air.shared.current!
        restoreID = options?[CBPeripheralManagerOptionRestoreIdentifierKey] as? String
        self.delegate = delegate
        super.init()
        device.peripherals.append(self)
        var restored: [String: Any]?
        if let id = restoreID, let old = device.retired.removeValue(forKey: id) as? CBPeripheralManager {
            restored = device.restoring.removeValue(forKey: id)
            services = old.services
            advertising = old.advertising
            remotes = old.remotes
            for link in Air.shared.connections where link.host === old { link.host = self }
        }
        Air.shared.later {
            if let restored { self.delegate?.peripheralManager(self, willRestoreState: restored) }
            self.delegate?.peripheralManagerDidUpdateState(self)
        }
    }

    public var state: CBManagerState {
        !device.authorized ? .unauthorized : device.powered ? .poweredOn : .poweredOff
    }

    private func requireOn(_ call: String) -> Bool {
        if state == .poweredOn { return true }
        Air.shared.violate("\(call) while not powered on")
        return false
    }

    func remote(_ device: Air.Device) -> CBCentral {
        if let existing = remotes[device.id] { return existing }
        let made = CBCentral()
        remotes[device.id] = made
        return made
    }

    func characteristic(_ uuid: CBUUID) -> CBMutableCharacteristic? {
        services.flatMap { $0.characteristics ?? [] }.first { $0.uuid == uuid } as? CBMutableCharacteristic
    }

    func reset() {
        services.removeAll()
        advertising = nil
        buffer.removeAll()
    }

    func unsubscribe(_ central: CBCentral) {
        for case let hosted as CBMutableCharacteristic in services.flatMap({ $0.characteristics ?? [] })
        where hosted.subscribedCentrals?.contains(central) == true {
            hosted.subscribedCentrals?.removeAll { $0 === central }
            Air.shared.later { self.delegate?.peripheralManager(self, central: central, didUnsubscribeFrom: hosted) }
        }
    }

    public func add(_ service: CBMutableService) {
        guard requireOn("add") else { return }
        services.append(service)
        Air.shared.later { self.delegate?.peripheralManager(self, didAdd: service, error: nil) }
    }

    public func removeAllServices() {
        guard requireOn("removeAllServices") else { return }
        services.removeAll()
    }

    public func startAdvertising(_ data: [String: Any]?) {
        guard requireOn("advertise") else { return }
        if advertising != nil { Air.shared.violate("advertise while already advertising") }
        let uuids = data?[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        // 28 bytes of foreground payload, 18 per 128-bit UUID.
        if uuids.count * 18 > 28 { Air.shared.violate("advertisement over 28 bytes") }
        if Air.shared.failingAdvertisements > 0 {
            Air.shared.failingAdvertisements -= 1
            return
        }
        advertising = uuids
    }

    public func stopAdvertising() {
        guard requireOn("stopAdvertising") else { return }
        advertising = nil
    }

    public func respond(to request: CBATTRequest, withResult result: CBATTError.Code) { request.answer() }

    public func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic, onSubscribedCentrals centrals: [CBCentral]?) -> Bool {
        guard requireOn("updateValue") else { return false }
        if value.count > Air.shared.mtu - 3 { Air.shared.violate("notify over MTU") }
        guard buffer.count < Air.shared.notifyBuffer else {
            wasFull = true
            Air.shared.countBackpressure()
            return false
        }
        buffer.append((value, characteristic.uuid, centrals ?? []))
        return true
    }

    func drain() {
        let sending = buffer
        buffer.removeAll()
        for item in sending {
            for link in Air.shared.connections where link.host === self && item.centrals.contains(link.remote) {
                let found = link.peripheral.services?.flatMap { $0.characteristics ?? [] }.first { $0.uuid == item.uuid }
                guard let characteristic = found, characteristic.isNotifying else { continue }
                characteristic.value = item.value
                link.peripheral.delegate?.peripheral(link.peripheral, didUpdateValueFor: characteristic, error: nil)
            }
        }
        if wasFull {
            wasFull = false
            delegate?.peripheralManagerIsReady(toUpdateSubscribers: self)
        }
    }
}
