// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "EncounterUI",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "EncounterUI", targets: ["EncounterUI"])
    ],
    targets: [
        .target(name: "EncounterUI"),
        .testTarget(name: "EncounterUITests", dependencies: ["EncounterUI"])
    ],
    swiftLanguageModes: [.v6]
)
