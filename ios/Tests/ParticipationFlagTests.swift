import Foundation
import XCTest
@testable import EngineerEncounters

final class ParticipationFlagTests: XCTestCase {
    @MainActor
    func testDefaultsOffAndPersistsExplicitParticipation() throws {
        let suite = "EngineerEncounters.ParticipationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flag = ParticipationFlag(defaults: defaults)
        XCTAssertFalse(flag.isEnabled)
        flag.isEnabled = true
        XCTAssertTrue(ParticipationFlag(defaults: defaults).isEnabled)
        flag.isEnabled = false
        XCTAssertFalse(ParticipationFlag(defaults: defaults).isEnabled)
    }
}
