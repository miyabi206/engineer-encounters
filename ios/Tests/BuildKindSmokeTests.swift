import XCTest
import EngineerEncounters

final class BuildKindSmokeTests: XCTestCase {
    func testBuildKindMatchesConfiguration() throws {
        let configuration = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "BuildConfiguration") as? String
        )

        switch configuration {
        case "Development":
            XCTAssertTrue(BuildKind.isDevelopment)
            XCTAssertFalse(BuildKind.isInternal)
        case "Internal":
            XCTAssertFalse(BuildKind.isDevelopment)
            XCTAssertTrue(BuildKind.isInternal)
        case "Release":
            XCTAssertFalse(BuildKind.isDevelopment)
            XCTAssertFalse(BuildKind.isInternal)
        default:
            XCTFail("Unexpected build configuration: \(configuration)")
        }
    }
}
