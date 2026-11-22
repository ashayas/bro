import BroKit
import Foundation

let usage = """
brobot: a bro that lives on your Mac, for testing Bro Chat with one iPhone.

  --code CODE      share a crew code
  --host           claim to host that crew
  --closed         code only
  --echo           bro back at whoever bros you
  --name A,B       name indices, 0...31 each
  --mood SLUG      your face (happy, angry, party, ...)
  --say SLUG       ("typed" for no sticker) bro on the Strip (and in the crew) every --every seconds
  --every N        default 10
  --ble / --lan    use only that radio (default: both)
  --for N          exit after N seconds
"""

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

func has(_ flag: String) -> Bool { arguments.contains(flag) }

func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if has("--help") {
    print(usage)
    exit(0)
}

var name = BroName.random()
if let parts = value("--name")?.split(separator: ",").compactMap({ UInt8($0) }), parts.count == 2,
   let chosen = BroName(first: parts[0], last: parts[1]) {
    name = chosen
}

let node = MeshNode(
    identity: Identity(), name: name,
    mood: value("--mood").flatMap { Mood(slug: $0) } ?? .chill, isOpen: !has("--closed")
)
let room = value("--code").flatMap { BroCode($0) }.map { Room(code: $0) }
if let room { node.setRooms([room], ownRoomID: has("--host") ? room.id : nil) }

var radios: [(label: String, transport: BroTransport)] = []
if !has("--lan") { radios.append(("bluetooth", BLETransport())) }
if !has("--ble") { radios.append(("wifi", LANTransport())) }
for radio in radios {
    node.attach(radio.transport)
    radio.transport.onStatus = { print("\(radio.label): \($0)") }
}

node.onEvent = { event in
    switch event {
    case let .bro(bro):
        print("bro \(bro.channel) \(bro.name.text): \(bro.line)\(bro.isVerified ? "" : " (heard on air)")")
        // Answering another bot's answer would loop forever, so never echo a respect.
        guard has("--echo"), bro.isVerified, bro.mood != .respect else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            node.say(bro.mood == .angry ? .shocked : .respect, in: bro.channel)
        }
    case let .ack(id, _, _):
        print("ack \(id.prefix(8))")
    case .peersChanged:
        print("in range: \(node.peers.values.map(\.name.text).sorted())")
    case .linksChanged:
        print("links: \(radios.map { "\($0.label)=\($0.transport.links.count)" }.joined(separator: " "))")
    }
}

print("\(name.text) is up\(node.isOpen ? ", open" : ", code only")\(room.map { ", crew \($0.code)" } ?? "")")
node.start()

if let slug = value("--say"), slug == "typed" || Mood(slug: slug) != nil {
    let mood = Mood(slug: slug)
    let interval = value("--every").flatMap(Double.init) ?? 10
    Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
        if node.isOpen { node.say(mood, in: .open) }
        if let room { node.say(mood, in: .room(room.id)) }
    }
}
if let seconds = value("--for").flatMap(Double.init) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        node.stop()
        exit(0)
    }
}
RunLoop.main.run()
