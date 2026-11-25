// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlightDeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FlightDeck", targets: ["FlightDeck"]),
        .library(name: "FlightDeckCore", targets: ["FlightDeckCore"]),
        .executable(name: "FlightDeckHelper", targets: ["FlightDeckHelper"]),
    ],
    targets: [
        .target(name: "FlightDeckCore", dependencies: ["FlightDeckHelperProtocol"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "FlightDeck", dependencies: ["FlightDeckCore", "FlightDeckHelperProtocol"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FlightDeckCoreTests", dependencies: ["FlightDeckCore", "FlightDeckHelperProtocol"]),
        .target(name: "FlightDeckHelperProtocol", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "FlightDeckHelperCore", dependencies: ["FlightDeckHelperProtocol"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "FlightDeckHelper", dependencies: ["FlightDeckHelperCore", "FlightDeckHelperProtocol"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FlightDeckHelperTests", dependencies: ["FlightDeckHelperProtocol", "FlightDeckHelperCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
