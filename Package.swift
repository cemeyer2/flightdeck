// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlightDeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FlightDeck", targets: ["FlightDeck"]),
        .library(name: "FlightDeckCore", targets: ["FlightDeckCore"]),
    ],
    targets: [
        .target(name: "FlightDeckCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "FlightDeck", dependencies: ["FlightDeckCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FlightDeckCoreTests", dependencies: ["FlightDeckCore"]),
    ]
)
