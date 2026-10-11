// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "EncounterDomain",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "EncounterDomain", targets: ["EncounterDomain"]),
        .library(name: "EncounterDomainTestSupport", targets: ["EncounterDomainTestSupport"])
    ],
    targets: [
        .target(name: "EncounterDomain"),
        .target(name: "EncounterDomainTestSupport", dependencies: ["EncounterDomain"]),
        .testTarget(name: "EncounterDomainTests", dependencies: ["EncounterDomain", "EncounterDomainTestSupport"])
    ],
    swiftLanguageModes: [.v6]
)
