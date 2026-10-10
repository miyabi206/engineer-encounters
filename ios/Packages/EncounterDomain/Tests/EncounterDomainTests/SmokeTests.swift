import XCTest
import EncounterDomain

final class SmokeTests: XCTestCase {
    func testPackageIsAvailable() {
        XCTAssertTrue(EncounterDomainPlaceholder.isAvailable)
    }
}
