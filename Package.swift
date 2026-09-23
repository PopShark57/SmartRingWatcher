// swift-tools-version:5.9
// The ring protocol layer is plain Foundation code shared with the watch app target, so it
// can be unit-tested on a Mac (or Linux) with `swift test` without a watch or a ring.
import PackageDescription

let package = Package(
    name: "RingProtocol",
    platforms: [.macOS(.v13), .iOS(.v16), .watchOS(.v10)],
    products: [
        .library(name: "RingProtocol", targets: ["RingProtocol"]),
    ],
    targets: [
        .target(name: "RingProtocol", path: "RingProtocol"),
        .testTarget(name: "RingProtocolTests", dependencies: ["RingProtocol"], path: "Tests/RingProtocolTests"),
    ]
)
