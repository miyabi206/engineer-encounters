// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "EncounterStorage",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "EncounterStorage", targets: ["EncounterStorage"])
    ],
    dependencies: [.package(path: "../EncounterDomain")],
    targets: [
        .target(name: "EncounterStorage", dependencies: [
            .product(name: "EncounterDomain", package: "EncounterDomain")
        ]),
        .testTarget(name: "EncounterStorageTests", dependencies: [
            "EncounterStorage",
            .product(name: "EncounterDomainTestSupport", package: "EncounterDomain")
        ])
    ],
    swiftLanguageModes: [.v6]
)
