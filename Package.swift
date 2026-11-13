// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Meterline",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Meterline", targets: ["Meterline"]),
        .library(name: "MeterCore", targets: ["MeterCore"]),
    ],
    targets: [
        .target(name: "MeterCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Meterline", dependencies: ["MeterCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MeterCoreTests", dependencies: ["MeterCore"]),
    ]
)
