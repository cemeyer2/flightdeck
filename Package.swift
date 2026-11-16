// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flightdeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Flightdeck", targets: ["Flightdeck"]),
        .library(name: "FlightdeckCore", targets: ["FlightdeckCore"]),
    ],
    targets: [
        .target(name: "FlightdeckCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Flightdeck", dependencies: ["FlightdeckCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FlightdeckCoreTests", dependencies: ["FlightdeckCore"]),
    ]
)
