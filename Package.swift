// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "terminal-mac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "terminal-mac", targets: ["TerminalMac"])],
    dependencies: [.package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.0")],
    targets: [
        .target(name: "TerminalMacCore"),
        .target(name: "CPhoneShim"),
        .target(name: "TerminalUI", dependencies: ["CPhoneShim"]),
        .target(name: "TerminalObserver", dependencies: ["TerminalMacCore"]),
        .executableTarget(name: "TerminalMac", dependencies: ["TerminalMacCore", "TerminalUI", "CPhoneShim", "TerminalObserver"],
            resources: [.copy("Auth")],
            linkerSettings: [.linkedFramework("Virtualization"), .linkedFramework("AppKit"),
                             .linkedFramework("ScreenCaptureKit"), .linkedFramework("ApplicationServices"), .linkedFramework("ServiceManagement"), .linkedFramework("CoreMedia"), .linkedFramework("Security")]),
        .testTarget(name: "TerminalMacTests", dependencies: ["TerminalMac", "TerminalObserver", "TerminalMacCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "TerminalMacCoreTests", dependencies: ["TerminalMacCore"]),
        .testTarget(name: "TerminalObserverTests", dependencies: ["TerminalObserver", "TerminalMacCore",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio")], resources: [.copy("Fixtures")]),
        .testTarget(name: "TerminalUITests", dependencies: ["TerminalUI", "TerminalMacCore"])
    ],
    swiftLanguageModes: [.v5]
)
