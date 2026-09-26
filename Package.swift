// swift-tools-version:6.0
// The watch app's logic that doesn't need a watch — the ring protocol, the health-data store,
// the sync engine and settings — is plain Foundation code. This package compiles those same
// files so they can be unit-tested on a Mac with `swift test`, without a watch or a ring.
import PackageDescription

let package = Package(
    name: "RingCore",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "RingCore", targets: ["RingCore"]),
    ],
    targets: [
        .target(
            name: "RingCore",
            path: ".",
            exclude: [
                "README.md", "docs", "Tests", "Shared", "SmartRingWatcher Widget",
                "SmartRingWatcher Watch App/App", "SmartRingWatcher Watch App/BLE",
                "SmartRingWatcher Watch App/Services", "SmartRingWatcher Watch App/Views",
                "SmartRingWatcher Watch App/Assets.xcassets", "SmartRingWatcher Watch App/Info.plist",
                "SmartRingWatcher Watch App/PrivacyInfo.xcprivacy", "SmartRingWatcher Watch App/Localizable.xcstrings",
                "SmartRingWatcher Watch App/SmartRingWatcher.entitlements",
            ],
            sources: [
                "RingProtocol",
                "SmartRingWatcher Watch App/Core",
            ]
        ),
        .testTarget(name: "RingProtocolTests", dependencies: ["RingCore"], path: "Tests/RingProtocolTests"),
        .testTarget(name: "AppCoreTests", dependencies: ["RingCore"], path: "Tests/AppCoreTests"),
    ]
)
