// swift-tools-version:5.9
import PackageDescription

// Debug builds (tests) honour OPPROXY_* test knobs; release builds, which install.sh
// installs, compile them out so an edited plist or environment can't switch them on.
let testing: [SwiftSetting] = [.define("OPPROXY_TESTING", .when(configuration: .debug))]

let package = Package(
    name: "opProxy",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "OpProxyCore", swiftSettings: testing),
        .executableTarget(name: "opProxy", dependencies: ["OpProxyCore"], swiftSettings: testing),
        .testTarget(name: "OpProxyCoreTests", dependencies: ["OpProxyCore"], swiftSettings: testing),
    ]
)
