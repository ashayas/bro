// swift-tools-version: 5.9
import PackageDescription

// Sources/BroRadio is a symlink to BroKit's sources, compiled against a fake CoreBluetooth.
let package = Package(
    name: "RadioLab",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "FakeCoreBluetooth"),
        .target(name: "BroRadio", dependencies: ["FakeCoreBluetooth"], swiftSettings: [.define("BRO_FAKE_RADIO")]),
        .testTarget(
            name: "RadioLabTests", dependencies: ["BroRadio", "FakeCoreBluetooth"],
            swiftSettings: [.define("BRO_FAKE_RADIO")]
        ),
    ]
)
