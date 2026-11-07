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
        .target(name: "TerminalObserver", dependencies: ["TerminalMacCore",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio")], resources: [.copy("Web")]),
        .executableTarget(name: "TerminalMac", dependencies: ["TerminalMacCore", "TerminalUI", "CPhoneShim", "TerminalObserver"],
            linkerSettings: [.linkedFramework("Virtualization"), .linkedFramework("AppKit"),
                             .linkedFramework("ScreenCaptureKit"), .linkedFramework("ApplicationServices"), .linkedFramework("ServiceManagement"), .linkedFramework("CoreMedia")]),
        .testTarget(name: "TerminalMacCoreTests", dependencies: ["TerminalMacCore"]),
        .testTarget(name: "TerminalObserverTests", dependencies: ["TerminalObserver", "TerminalMacCore",
            .product(name: "NIOEmbedded", package: "swift-nio")]),
        .testTarget(name: "TerminalUITests", dependencies: ["TerminalUI", "TerminalMacCore"])
    ],
    swiftLanguageModes: [.v5]
)
