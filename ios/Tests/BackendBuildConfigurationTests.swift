import EncounterBackend
import EncounterDomain
import Foundation
import XCTest
@testable import EngineerEncounters

@MainActor
final class BackendBuildConfigurationTests: XCTestCase {
    func testHTTPIsAcceptedOnlyInDevelopmentIncludingMixedCaseSchemes() {
        let fixture = appBackendTestConfiguration()
        for scheme in ["http", "HTTP", "https", "HTTPS"] {
            let address = fixture.address.absoluteString.replacingOccurrences(of: "https", with: scheme)
            let configuration = AppComposition.backendConfiguration(info: [
                "BackendURL": address, "BackendPublicKey": fixture.publicClientKey
            ])
            if scheme.lowercased() == "https" || BuildKind.isDevelopment {
                XCTAssertNotNil(configuration)
            } else {
                XCTAssertNil(configuration)
            }
        }
    }

    func testBuildSettingsSelectAnIndependentAddressAndKeyForEveryBuildKind() throws {
        let project = try resource("project", extension: "yml")
        let settingsStart = try XCTUnwrap(project.range(of: "settings:\n"))
        let settingsEnd = try XCTUnwrap(project.range(of: "packages:\n"))
        let settings = String(project[settingsStart.upperBound..<settingsEnd.lowerBound])
        let kinds = ["Development", "Internal", "Release"]
        for (index, kind) in kinds.enumerated() {
            let start = try XCTUnwrap(settings.range(of: "    \(kind):\n"))
            let end = index + 1 < kinds.count
                ? try XCTUnwrap(settings.range(of: "    \(kinds[index + 1]):\n")).lowerBound
                : settings.endIndex
            let section = String(settings[start.upperBound..<end])
            let prefix = kind.uppercased()
            XCTAssertTrue(section.contains("BACKEND_URL: $(\(prefix)_BACKEND_URL)"))
            XCTAssertTrue(section.contains("BACKEND_PUBLIC_KEY: $(\(prefix)_BACKEND_PUBLIC_KEY)"))
            for other in kinds where other != kind {
                XCTAssertFalse(section.contains("$(\(other.uppercased())_BACKEND_"))
            }
        }
    }

    func testInjectedHTTPConfigurationCannotBypassBuildKindRestrictions() async throws {
        let fixture = appBackendTestConfiguration()
        let configuration = try XCTUnwrap(EncounterBackend.BackendConfiguration(
            address: fixture.address.absoluteString.replacingOccurrences(of: "https", with: "http"),
            publicClientKey: fixture.publicClientKey))
        let keychain = AppMemoryKeychain()
        let composition = AppComposition(configuration: configuration, defaults: appBackendDefaults(),
            keychain: keychain, queueOpener: { EncounterDomain.InMemoryReceiptQueue() })
        await composition.waitForRestoration()
        #if DEVELOPMENT_BUILD
        XCTAssertEqual(composition.account.state, .signedOut)
        #else
        XCTAssertEqual(composition.account.state, .unavailable)
        let reads = await keychain.reads
        XCTAssertEqual(reads, 0)
        #endif
        XCTAssertNil(composition.runtime)
    }

    func testSharedDefaultsAndShippedExampleLeaveAllBackendValuesEmpty() throws {
        for contents in [try resource("Shared", extension: "xcconfig"),
                         try resource("Local.xcconfig", extension: "example")] {
            let lines = contents.components(separatedBy: .newlines).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            for kind in ["DEVELOPMENT", "INTERNAL", "RELEASE"] {
                for field in ["URL", "PUBLIC_KEY"] {
                    let key = "\(kind)_BACKEND_\(field)"
                    XCTAssertEqual(lines.filter { $0.hasPrefix(key + " =") }, [key + " ="])
                }
            }
            XCTAssertFalse(lines.contains { $0.hasPrefix("BACKEND_URL =") || $0.hasPrefix("BACKEND_PUBLIC_KEY =") })
        }
    }

    private func resource(_ name: String, extension fileExtension: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: BackendBuildConfigurationTests.self).url(forResource: name, withExtension: fileExtension))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
