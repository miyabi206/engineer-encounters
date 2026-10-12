// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "EncounterBackend",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "EncounterBackend", targets: ["EncounterBackend"])
    ],
    dependencies: [
        .package(path: "../EncounterDomain")
    ],
    targets: [
        .target(name: "EncounterBackend", dependencies: ["EncounterDomain"]),
        .testTarget(name: "EncounterBackendTests", dependencies: [
            "EncounterBackend", .product(name: "EncounterDomainTestSupport", package: "EncounterDomain")
        ])
    ],
    swiftLanguageModes: [.v6]
)
