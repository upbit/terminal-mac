// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "terminal-mac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "terminal-mac", targets: ["TerminalMac"])],
    dependencies: [
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", exact: "2.6.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", exact: "2.6.0"),
        // Newer swift-log releases require compiler attributes unavailable in Swift 6.2.
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.1")
    ],
    targets: [
        .target(name: "TerminalMacCore"),
        .target(name: "TerminalMacTracing", dependencies: [
            "TerminalMacCore",
            .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
            .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
            .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift")
        ]),
        .target(name: "CPhoneShim"),
        .target(name: "TerminalUI", dependencies: ["CPhoneShim"]),
        .executableTarget(name: "TerminalMac", dependencies: ["TerminalMacCore", "TerminalMacTracing", "TerminalUI", "CPhoneShim"],
            linkerSettings: [.linkedFramework("Virtualization"), .linkedFramework("AppKit"),
                             .linkedFramework("ScreenCaptureKit"), .linkedFramework("ApplicationServices"), .linkedFramework("ServiceManagement"), .linkedFramework("CoreMedia")]),
        .testTarget(name: "TerminalMacCoreTests", dependencies: ["TerminalMacCore"]),
        .testTarget(name: "TerminalMacTracingTests", dependencies: ["TerminalMacTracing", "TerminalMac"]),
        .testTarget(name: "TerminalUITests", dependencies: ["TerminalUI", "TerminalMacCore"])
    ],
    swiftLanguageModes: [.v5]
)
