// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BroKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "BroKit", targets: ["BroKit"])],
    targets: [
        .target(name: "BroKit"),
        .testTarget(name: "BroKitTests", dependencies: ["BroKit"]),
    ]
)
