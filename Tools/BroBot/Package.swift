// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BroBot",
    platforms: [.macOS(.v12)],
    dependencies: [.package(path: "../../BroKit")],
    targets: [
        .executableTarget(
            name: "brobot",
            dependencies: [.product(name: "BroKit", package: "BroKit")],
            exclude: ["Info.plist"],
            // macOS won't allow Bluetooth to a binary without an embedded usage description.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/brobot/Info.plist",
            ])]
        ),
    ]
)
