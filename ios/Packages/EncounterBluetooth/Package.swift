// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "EncounterBluetooth",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "EncounterBluetooth", targets: ["EncounterBluetooth"])
    ],
    targets: [
        .target(name: "EncounterBluetooth"),
        .testTarget(name: "EncounterBluetoothTests", dependencies: ["EncounterBluetooth"])
    ],
    swiftLanguageModes: [.v6]
)
