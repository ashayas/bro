import BroKit
import Foundation

struct Person: Codable, Equatable {
    var name: BroName
    var mood: Mood
    var key: Data?
}

struct Settings: Codable, Equatable {
    var bluetooth = true
    var wifi = true
    var voice = true
    var effects = true
    var haptics = true
    var notifications = true
}

/// Everything we persist. It never leaves the phone.
struct SavedState: Codable {
    var onboarded = false
    var name = BroName.random()
    var mood = Mood.happy
    var isOpen = true
    var ownRoom = Room(code: .random())
    var joined: [Room] = []
    var roomHosts: [String: BroName] = [:]
    var people: [String: Person] = [:]
    var roommates: [String: Set<String>] = [:]
    var invited: Set<String> = []
    var blocked: Set<String> = []
    var bros: [Bro] = []
    var receipts: [String: Set<String>] = [:]
    var unread: [Channel: Int] = [:]
    var outbox: [OutboxItem] = []
    var settings = Settings()
}

struct Disk {
    private let folder: URL
    private var stateURL: URL { folder.appendingPathComponent("state.json") }
    private var identityURL: URL { folder.appendingPathComponent("identity.key") }

    /// False when a file exists but is unreadable (launched before first unlock).
    /// Saving then would replace the real identity with a blank one.
    private(set) var canSave = true

    init() {
        var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BroChat", isDirectory: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-reset") {
            try? FileManager.default.removeItem(at: folder)
        }
        #endif
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        // An identity restored onto a second phone would be two bros with one face.
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        self.folder = folder
    }

    mutating func loadIdentity() -> Identity {
        if FileManager.default.fileExists(atPath: identityURL.path) {
            guard let data = try? Data(contentsOf: identityURL) else {
                canSave = false
                return Identity()
            }
            if let identity = Identity(stored: data) { return identity }
        }
        let identity = Identity()
        write(identity.stored, to: identityURL)
        return identity
    }

    mutating func loadState() -> SavedState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return SavedState() }
        guard let data = try? Data(contentsOf: stateURL) else {
            canSave = false
            return SavedState()
        }
        if let state = try? JSONDecoder().decode(SavedState.self, from: data) { return state }
        write(data, to: folder.appendingPathComponent("state.unreadable.json"))
        return SavedState()
    }

    func save(_ state: SavedState) {
        guard canSave, let data = try? JSONEncoder().encode(state) else { return }
        write(data, to: stateURL)
    }

    private func write(_ data: Data, to url: URL) {
        guard canSave else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
