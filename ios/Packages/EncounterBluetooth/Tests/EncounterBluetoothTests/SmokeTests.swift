import XCTest
import EncounterBluetooth

final class SmokeTests: XCTestCase {
    func testPackageIsAvailable() {
        XCTAssertTrue(EncounterBluetoothPlaceholder.isAvailable)
    }
}
