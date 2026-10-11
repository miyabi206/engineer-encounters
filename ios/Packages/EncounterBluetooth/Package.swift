// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "EncounterBluetooth",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "EncounterBluetooth", targets: ["EncounterBluetooth"])
    ],
    dependencies: [.package(path: "../EncounterDomain")],
    targets: [
        .target(name: "EncounterBluetooth", dependencies: [
            .product(name: "EncounterDomain", package: "EncounterDomain")
        ]),
        .testTarget(name: "EncounterBluetoothTests", dependencies: [
            "EncounterBluetooth",
            .product(name: "EncounterDomain", package: "EncounterDomain")
        ])
    ],
    swiftLanguageModes: [.v6]
)
