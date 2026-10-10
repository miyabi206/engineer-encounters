import XCTest
import EncounterBackend

final class SmokeTests: XCTestCase {
    func testPackageIsAvailable() {
        XCTAssertTrue(EncounterBackendPlaceholder.isAvailable)
    }
}
