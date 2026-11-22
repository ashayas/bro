// RadioLab compiles this file against an in-memory CoreBluetooth to test it without two phones.
#if BRO_FAKE_RADIO
import FakeCoreBluetooth
#else
import CoreBluetooth
#endif
import Foundation

/// Bluetooth LE, with no internet, router or pairing.
///
/// Every phone is a central and a peripheral at once. Packets travel as a framed byte stream over
/// one characteristic: writes toward the peripheral, notifications toward the central.
/// Open bros are also shouted as advertisements (see `AirShout`).
public final class BLETransport: NSObject, BroTransport {
    static let serviceUUID = CBUUID(string: "8E4B1B20-6D5C-4B7E-9A51-B0B0B0C4A701")
    static let streamUUID = CBUUID(string: "8E4B1B21-6D5C-4B7E-9A51-B0B0B0C4A701")

    private enum Limits {
        static let outgoingLinks = 6
        static let provisionalWriters = 16
        static let provisionalLifetime: TimeInterval = 30
        static let queuedBytes = 48 * 1024
        static let connectTimeout: TimeInterval = 15
        static let retryDelay: TimeInterval = 4
        static let rescan: TimeInterval = 10
        static let shoutWindow: TimeInterval = 1.2
        static let beaconWindow: TimeInterval = 0.8
        static let shoutRepeats = 3
    }

    private final class Outgoing {
        let peripheral: CBPeripheral
        let link: LinkID
        var stream: CBCharacteristic?
        var framer = StreamFramer()
        var queue: [Data] = []
        var queuedBytes = 0
        var writing = false
        var ready = false
        var started = Date()

        init(_ peripheral: CBPeripheral) {
            self.peripheral = peripheral
            link = "ble/out/\(peripheral.identifier.uuidString)"
        }
    }

    private final class Incoming {
        var central: CBCentral
        let link: LinkID
        var framer = StreamFramer()
        var queue: [Data] = []
        var queuedBytes = 0
        var ready = false
        let created = Date()

        init(_ central: CBCentral) {
            self.central = central
            link = "ble/in/\(central.identifier.uuidString)"
        }
    }

    public private(set) var status: TransportStatus = .off {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    public var links: Set<LinkID> {
        Set(outgoing.values.filter(\.ready).map(\.link) + incoming.values.filter(\.ready).map(\.link))
    }
    public var onPacket: ((Data, LinkID) -> Void)?
    public var onLinkUp: ((LinkID) -> Void)?
    public var onLinkDown: ((LinkID) -> Void)?
    public var onStatus: ((TransportStatus) -> Void)?
    public var onShout: ((AirShout) -> Void)?

    private let restorationID: String?
    private var running = false
    private var foreground = true

    private var central: CBCentralManager?
    // A filtered scan works in the background. An unfiltered one hears shouts. A manager runs one scan, so two.
    private var listener: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var stream: CBMutableCharacteristic?
    private var serviceAdded = false

    private var outgoing: [UUID: Outgoing] = [:]
    private var incoming: [UUID: Incoming] = [:]
    private var retryAfter: [UUID: Date] = [:]
    private var shouts: [(shout: AirShout, left: Int)] = []
    private var airTimer: Timer?
    private var housekeeping: Timer?
    private var lastScan = Date.distantPast

    public init(restorationID: String? = nil) {
        self.restorationID = restorationID
        super.init()
    }

    // MARK: BroTransport

    public func start() {
        guard !running else { return }
        running = true
        status = .starting
        var centralOptions: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
        var peripheralOptions: [String: Any] = [CBPeripheralManagerOptionShowPowerAlertKey: false]
        #if os(iOS) || BRO_FAKE_RADIO
        if let restorationID {
            centralOptions[CBCentralManagerOptionRestoreIdentifierKey] = "\(restorationID).central"
            peripheralOptions[CBPeripheralManagerOptionRestoreIdentifierKey] = "\(restorationID).peripheral"
        }
        #endif
        central = CBCentralManager(delegate: self, queue: .main, options: centralOptions)
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main, options: peripheralOptions)
        listener = CBCentralManager(
            delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
        housekeeping = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.housekeep()
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        housekeeping?.invalidate()
        housekeeping = nil
        endShouting()
        if central?.state == .poweredOn {
            central?.stopScan()
            for state in outgoing.values { central?.cancelPeripheralConnection(state.peripheral) }
        }
        if listener?.state == .poweredOn { listener?.stopScan() }
        if peripheralManager?.state == .poweredOn {
            peripheralManager?.stopAdvertising()
            peripheralManager?.removeAllServices()
        }
        dropOutgoing()
        dropIncoming()
        central = nil
        listener = nil
        peripheralManager = nil
        stream = nil
        serviceAdded = false
        status = .off
    }

    public func setForeground(_ value: Bool) {
        guard value != foreground else { return }
        foreground = value
        updateListener()
        // iOS strips shout UUIDs in the background, so don't spend airtime on them.
        if !value {
            endShouting()
            advertiseBeacon()
        } else {
            scan()
        }
    }

    public func send(_ packet: Data, to link: LinkID) {
        let framed = StreamFramer.frame(packet)
        if let state = outgoing.values.first(where: { $0.link == link }), state.ready {
            guard state.queuedBytes + framed.count <= Limits.queuedBytes else { return }
            let size = max(20, state.peripheral.maximumWriteValueLength(for: .withoutResponse))
            state.queue.append(contentsOf: Self.chunks(framed, size: size))
            state.queuedBytes += framed.count
            write(state)
        } else if let state = incoming.values.first(where: { $0.link == link }), state.ready {
            guard state.queuedBytes + framed.count <= Limits.queuedBytes else { return }
            state.queue.append(contentsOf: Self.chunks(framed, size: max(20, state.central.maximumUpdateValueLength)))
            state.queuedBytes += framed.count
            notify()
        }
    }

    public func shout(_ shout: AirShout) {
        guard running, foreground, peripheralManager?.state == .poweredOn else { return }
        shouts.append((shout, Limits.shoutRepeats))
        if shouts.count > 4 { shouts.removeFirst() }
        if airTimer == nil { shoutNext() }
    }

    public func cancelShouts() {
        guard !shouts.isEmpty || airTimer != nil else { return }
        endShouting()
        advertiseBeacon()
    }

    static func chunks(_ data: Data, size: Int) -> [Data] {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: size).map {
            Data(bytes[$0..<min($0 + size, bytes.count)])
        }
    }

    // MARK: Advertising

    private func advertiseBeacon() {
        guard running, serviceAdded, let manager = peripheralManager, manager.state == .poweredOn else { return }
        manager.stopAdvertising()
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
    }

    /// Alternates shout and beacon, so we stay discoverable while shouting.
    private func shoutNext() {
        guard !shouts.isEmpty, let manager = peripheralManager, manager.state == .poweredOn else {
            endShouting()
            advertiseBeacon()
            return
        }
        var next = shouts.removeFirst()
        manager.stopAdvertising()
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(data: next.shout.uuidBytes())]])
        next.left -= 1
        if next.left > 0 { shouts.append(next) }
        airTimer = .scheduledTimer(withTimeInterval: Limits.shoutWindow, repeats: false) { [weak self] _ in
            self?.advertiseBeacon()
            self?.airTimer = .scheduledTimer(withTimeInterval: Limits.beaconWindow, repeats: false) { [weak self] _ in
                self?.airTimer = nil
                if self?.shouts.isEmpty == false { self?.shoutNext() }
            }
        }
    }

    private func endShouting() {
        airTimer?.invalidate()
        airTimer = nil
        shouts.removeAll()
    }

    // MARK: Scanning

    private func scan() {
        guard running, let central, central.state == .poweredOn else { return }
        lastScan = Date()
        central.stopScan()
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    private func updateListener() {
        guard running, let listener, listener.state == .poweredOn else { return }
        if foreground {
            listener.scanForPeripherals(
                withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        } else {
            listener.stopScan()
        }
    }

    private func housekeep() {
        guard running, let central, central.state == .poweredOn else { return }
        let now = Date()
        // startAdvertising can fail (another app has the radio). Keep asking.
        if airTimer == nil, let manager = peripheralManager, manager.state == .poweredOn, !manager.isAdvertising {
            advertiseBeacon()
        }
        // A writer that never subscribed never sends an unsubscribe either.
        for (id, state) in incoming where !state.ready && now.timeIntervalSince(state.created) > Limits.provisionalLifetime {
            incoming[id] = nil
            onLinkDown?(state.link)
        }
        // In the background a pending connect is how we get woken, so only give up in the foreground.
        if foreground {
            for (id, state) in outgoing where !state.ready && now.timeIntervalSince(state.started) > Limits.connectTimeout {
                outgoing[id] = nil
                retryAfter[id] = now.addingTimeInterval(Limits.retryDelay)
                central.cancelPeripheralConnection(state.peripheral)
            }
        }
        retryAfter = retryAfter.filter { $0.value > now }
        // Without duplicates a scan reports each phone once, so restart it to see retries.
        if now.timeIntervalSince(lastScan) >= Limits.rescan { scan() }
    }

    // MARK: Central side

    private func connect(_ peripheral: CBPeripheral) {
        guard let central, central.state == .poweredOn, outgoing[peripheral.identifier] == nil else { return }
        if outgoing.count >= Limits.outgoingLinks {
            // Someone here now beats waiting for someone who left.
            guard let stale = outgoing.values.filter({ !$0.ready }).min(by: { $0.started < $1.started }),
                  Date().timeIntervalSince(stale.started) > Limits.retryDelay else { return }
            outgoing[stale.peripheral.identifier] = nil
            central.cancelPeripheralConnection(stale.peripheral)
        }
        outgoing[peripheral.identifier] = Outgoing(peripheral)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    private func abandon(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        retryAfter[id] = Date().addingTimeInterval(Limits.retryDelay)
        if let state = outgoing.removeValue(forKey: id), state.ready { onLinkDown?(state.link) }
        if central?.state == .poweredOn { central?.cancelPeripheralConnection(peripheral) }
    }

    private func write(_ state: Outgoing) {
        guard !state.writing, let stream = state.stream, let chunk = state.queue.first else { return }
        state.writing = true
        state.peripheral.writeValue(chunk, for: stream, type: .withResponse)
    }

    private func dropOutgoing() {
        let gone = outgoing.values.filter(\.ready)
        outgoing.removeAll()
        gone.forEach { onLinkDown?($0.link) }
    }

    // MARK: Peripheral side

    private func publishService() {
        guard let manager = peripheralManager else { return }
        let characteristic = CBMutableCharacteristic(
            type: Self.streamUUID, properties: [.write, .notify], value: nil, permissions: [.writeable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        stream = characteristic
        manager.removeAllServices()
        manager.add(service)
    }

    private func notify() {
        guard let manager = peripheralManager, let stream else { return }
        // One chunk each per pass, so a slow central can't starve the others.
        var sentAny = true
        while sentAny {
            sentAny = false
            for state in Array(incoming.values) {
                guard let chunk = state.queue.first else { continue }
                // False means the shared buffer is full. `isReady` calls us back.
                guard manager.updateValue(chunk, for: stream, onSubscribedCentrals: [state.central]) else { return }
                state.queue.removeFirst()
                state.queuedBytes -= chunk.count
                sentAny = true
            }
        }
    }

    private func dropIncoming() {
        let gone = incoming.values.filter(\.ready)
        incoming.removeAll()
        gone.forEach { onLinkDown?($0.link) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard running else { return }
        if manager === listener {
            updateListener()
            return
        }
        switch manager.state {
        case .poweredOn:
            status = .ready
            for state in outgoing.values {
                state.peripheral.delegate = self
                if state.peripheral.state == .connected {
                    state.peripheral.discoverServices([Self.serviceUUID])
                } else {
                    manager.connect(state.peripheral, options: nil)
                }
            }
            scan()
        case .poweredOff:
            status = .poweredOff
            dropOutgoing()
        case .unauthorized:
            status = .denied
            dropOutgoing()
        case .unsupported:
            status = .unsupported
        case .resetting:
            status = .starting
            dropOutgoing()
        default:
            // .unknown comes before .poweredOn and must not wipe restored peripherals.
            status = .starting
        }
    }

    #if os(iOS) || BRO_FAKE_RADIO
    public func centralManager(_ manager: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard manager !== listener else { return }
        for peripheral in dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [] {
            outgoing[peripheral.identifier] = Outgoing(peripheral)
            peripheral.delegate = self
        }
    }
    #endif

    public func centralManager(
        _ manager: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        guard running else { return }
        if manager === listener {
            for uuid in advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [] {
                if let shout = AirShout(uuidBytes: uuid.data) { onShout?(shout) }
            }
            return
        }
        if let until = retryAfter[peripheral.identifier], until > Date() { return }
        connect(peripheral)
    }

    public func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard manager === central, let state = outgoing[peripheral.identifier] else { return }
        state.started = Date()
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard manager === central, outgoing[peripheral.identifier] != nil else { return }
        abandon(peripheral)
    }

    public func centralManager(
        _ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        guard manager === central, let state = outgoing.removeValue(forKey: peripheral.identifier) else { return }
        guard state.ready else {
            retryAfter[peripheral.identifier] = Date().addingTimeInterval(Limits.retryDelay)
            return
        }
        onLinkDown?(state.link)
        // A pending connect has no timeout in the background: walk back into camp and it relinks.
        if running { connect(peripheral) }
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard outgoing[peripheral.identifier] != nil else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            return abandon(peripheral)
        }
        peripheral.discoverCharacteristics([Self.streamUUID], for: service)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard let state = outgoing[peripheral.identifier] else { return }
        guard error == nil,
              let found = service.characteristics?.first(where: { $0.uuid == Self.streamUUID })
        else { return abandon(peripheral) }
        state.stream = found
        if found.isNotifying {
            markReady(state)
        } else {
            peripheral.setNotifyValue(true, for: found)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard let state = outgoing[peripheral.identifier] else { return }
        guard error == nil, characteristic.isNotifying else { return abandon(peripheral) }
        markReady(state)
    }

    private func markReady(_ state: Outgoing) {
        guard !state.ready else { return }
        state.ready = true
        onLinkUp?(state.link)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.streamUUID, let value = characteristic.value,
              let state = outgoing[peripheral.identifier] else { return }
        state.framer.append(value).forEach { onPacket?($0, state.link) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let state = outgoing[peripheral.identifier] else { return }
        guard error == nil else { return abandon(peripheral) }
        state.writing = false
        if !state.queue.isEmpty { state.queuedBytes -= state.queue.removeFirst().count }
        write(state)
    }

    /// How we find out the other app quit while the radio connection stayed up.
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard outgoing[peripheral.identifier] != nil,
              invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) else { return }
        abandon(peripheral)
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLETransport: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        guard running else { return }
        if manager.state == .poweredOn {
            if serviceAdded {
                advertiseBeacon()
                for state in Array(incoming.values) where state.ready { onLinkUp?(state.link) }
            } else {
                publishService()
            }
        } else {
            serviceAdded = false
            endShouting()
            dropIncoming()
        }
    }

    #if os(iOS) || BRO_FAKE_RADIO
    public func peripheralManager(_ manager: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        guard let service = services.first(where: { $0.uuid == Self.serviceUUID }),
              let restored = service.characteristics?.first(where: { $0.uuid == Self.streamUUID })
                as? CBMutableCharacteristic
        else { return }
        stream = restored
        serviceAdded = true
        for central in restored.subscribedCentrals ?? [] {
            let state = Incoming(central)
            state.ready = true
            incoming[central.identifier] = state
        }
    }
    #endif

    public func peripheralManager(_ manager: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            status = .failed(error.localizedDescription)
            return
        }
        serviceAdded = true
        advertiseBeacon()
    }

    public func peripheralManager(
        _ manager: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic
    ) {
        let state = incoming[central.identifier] ?? Incoming(central)
        state.central = central
        incoming[central.identifier] = state
        guard !state.ready else { return }
        state.ready = true
        onLinkUp?(state.link)
    }

    public func peripheralManager(
        _ manager: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard let state = incoming.removeValue(forKey: central.identifier) else { return }
        if state.ready { onLinkDown?(state.link) }
    }

    public func peripheralManager(_ manager: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        // We chunk below the MTU, so an offset means a long write that isn't ours.
        // A batch is all or nothing, and gets one response, for its first request.
        guard requests.allSatisfy({ $0.offset == 0 && $0.characteristic.uuid == Self.streamUUID }) else {
            manager.respond(to: first, withResult: .invalidOffset)
            return
        }
        manager.respond(to: first, withResult: .success)
        for request in requests {
            guard let value = request.value else { continue }
            let known = incoming[request.central.identifier]
            if known == nil, incoming.values.filter({ !$0.ready }).count >= Limits.provisionalWriters { continue }
            // A write can beat the subscription callback.
            let state = known ?? Incoming(request.central)
            incoming[request.central.identifier] = state
            state.framer.append(value).forEach { onPacket?($0, state.link) }
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers manager: CBPeripheralManager) {
        notify()
    }
}
