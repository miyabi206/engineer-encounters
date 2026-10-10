import XCTest
import EncounterStorage

final class SmokeTests: XCTestCase {
    func testPackageIsAvailable() {
        XCTAssertTrue(EncounterStoragePlaceholder.isAvailable)
    }
}
