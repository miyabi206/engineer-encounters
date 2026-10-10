// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "EncounterDomain",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "EncounterDomain", targets: ["EncounterDomain"])
    ],
    targets: [
        .target(name: "EncounterDomain"),
        .testTarget(name: "EncounterDomainTests", dependencies: ["EncounterDomain"])
    ],
    swiftLanguageModes: [.v6]
)
