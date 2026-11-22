# Protocol

Source of truth: `BroKit/Sources/BroKit/Wire.swift` and `MeshNode.swift`.

## Packets

An envelope is `version | ttl | kind | payload`. Its ID is a hash of kind and payload, so relays can deduplicate and nobody can forge an ID to suppress a packet.

| Kind | Who can read it | Payload |
|---|---|---|
| open | anyone in range | signed message |
| room | holders of the code | AES-GCM under a key derived from the code |
| direct | one person | ephemeral X25519 key, then AES-GCM |

A message is Ed25519-signed over its channel, so it can't be replayed into another one. Its body is presence (mood, host flag), bro (mood), ack (message ID) or goodbye. All fixed size, no strings.

The mood byte is 0-15 for moods, 16 for "go to entrance", 17 for "go to checkout" and `0xFF` for a typed bro (no sticker). Builds older than these values drop such messages, so update every phone together.

## Who hears you

| Receiver is | The Strip | Direct | Crew |
|---|---|---|---|
| Open | yes | from anyone | with the code |
| Code only | no | from crewmates, or people they messaged first | with the code |

Replacing or leaving a code revokes the direct-message allowance it granted.

## Mesh

- Packets flood for an origin plus four relays. Relays can't read sealed packets.
- A new link receives the last two minutes of traffic.
- An unacknowledged direct bro retries for 15 minutes, including across app relaunches.
- Presence goes out every 12 seconds and expires after 40.

## Bluetooth

Every phone is both central and peripheral, with one service and one write/notify characteristic carrying length-framed packets. Multipeer Connectivity isn't used because it no longer runs over Bluetooth.

A shout is one 16-byte service UUID: `magic(3) mood(1) name(2) event(8) checksum(2)`. iOS lets an app advertise only a name and service UUIDs, and iOS 26 is reported to truncate names, hence the UUID. The checksum includes a ten-minute window.

## Limits

- **Shouts are unsigned.** Anyone with a BLE radio can fake one. They're labelled unverified, never notify, and are replaced by the signed copy when it arrives.
- **A code is a shared secret.** Anyone who has it can read that room and pass it on, and a member could claim to be host. Codes have 40 bits behind a slow key derivation, which is good for this app but is not a secure messenger.
- **No forward secrecy** against theft of a recipient's key or of a room code.
- **Open traffic is public** and carries a stable pseudonymous ID while you are open.
- **Clocks** more than 15 minutes apart reject each other's messages.
- **Background:** existing links keep working. Two pocketed phones may not discover each other until one screen wakes. A force-quit app goes dark. Wi-Fi works only while the app is open, plus about 15 seconds.
- This hasn't had a professional security audit.
