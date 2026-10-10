// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "EncounterBackend",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "EncounterBackend", targets: ["EncounterBackend"])
    ],
    targets: [
        .target(name: "EncounterBackend"),
        .testTarget(name: "EncounterBackendTests", dependencies: ["EncounterBackend"])
    ],
    swiftLanguageModes: [.v6]
)
