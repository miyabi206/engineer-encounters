import XCTest
import EncounterUI

final class SmokeTests: XCTestCase {
    func testPackageIsAvailable() {
        XCTAssertTrue(EncounterUIPlaceholder.isAvailable)
    }
}
