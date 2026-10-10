// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "EncounterStorage",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "EncounterStorage", targets: ["EncounterStorage"])
    ],
    targets: [
        .target(name: "EncounterStorage"),
        .testTarget(name: "EncounterStorageTests", dependencies: ["EncounterStorage"])
    ],
    swiftLanguageModes: [.v6]
)
