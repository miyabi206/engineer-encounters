#if DEVELOPMENT_BUILD || INTERNAL_BUILD
import EncounterDomain
import Foundation
import XCTest
@testable import EngineerEncounters

final class DiagnosticsTests: XCTestCase {
    @MainActor
    func testElapsedUsesContinuousClockAndPersistsEveryMeasurement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.recorder.beginIfNeeded(metadata: fixture.metadata)
        XCTAssertEqual(try fixture.read().count, 1)
        let peer = PeerHandle()
        fixture.clock.seconds = 12.5
        fixture.wall.date = fixture.wall.date.addingTimeInterval(3600)
        fixture.recorder.record(.peerFirstObserved(peer))
        XCTAssertEqual(try fixture.read()[0].discoveryElapsedSeconds, 12.5)
        fixture.clock.seconds = 19
        fixture.recorder.record(.peerFirstObserved(PeerHandle()))
        XCTAssertEqual(try fixture.read()[0].distinctPeerCount, 2)
        XCTAssertEqual(try fixture.read()[0].discoveryElapsedSeconds, 12.5)
        fixture.clock.seconds = 24
        fixture.recorder.record(.exchangeCompleted(role: .central, nonceDigest: "digest-one"))
        XCTAssertEqual(try fixture.read()[0].exchanges[0].elapsedSeconds, 24)
        fixture.clock.seconds = 132
        fixture.recorder.record(.evidenceReached(role: .central, nonceDigest: "digest-one", observedDuration: 120))
        let evidence = try fixture.read()[0].evidence[0]
        XCTAssertEqual(evidence.role, .central)
        XCTAssertEqual(evidence.exchangeDigest, "digest-one")
        XCTAssertEqual(evidence.elapsedSeconds, 132)
        XCTAssertEqual(evidence.observedDurationSeconds, 120)
        XCTAssertEqual(try fixture.read()[0].serverConfirmation, .unavailable)
    }

    @MainActor
    func testMissingPendingAndSecondExchangeRemainSeparate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var metadata = fixture.metadata
        metadata.presenceApproach = "secondExchange"
        fixture.recorder.beginIfNeeded(metadata: metadata)
        var trial = try XCTUnwrap(fixture.log.records.first)
        XCTAssertEqual(trial.discoveryState, .pending)
        XCTAssertEqual(trial.exchangeState, .pending)
        XCTAssertEqual(trial.evidenceState, .pending)
        XCTAssertEqual(trial.serverConfirmation, .unavailable)
        fixture.clock.seconds = 2
        fixture.recorder.record(.exchangeCompleted(role: .peripheral, nonceDigest: "first"))
        fixture.clock.seconds = 123
        fixture.recorder.record(.exchangeCompleted(role: .peripheral, nonceDigest: "second"))
        fixture.recorder.record(.evidenceReached(role: .peripheral, nonceDigest: "second", observedDuration: 121))
        trial = try XCTUnwrap(fixture.log.records.first)
        XCTAssertEqual(trial.exchanges.map(\.exchangeDigest), ["first", "second"])
        XCTAssertEqual(trial.exchanges.map(\.elapsedSeconds), [2, 123])
        XCTAssertEqual(trial.evidence.map(\.exchangeDigest), ["second"])
        XCTAssertEqual(trial.evidenceState(for: trial.exchanges[0]), .pending)
        XCTAssertEqual(trial.evidenceState(for: trial.exchanges[1]), .recorded)
        fixture.recorder.close()
        trial = try XCTUnwrap(fixture.log.records.first)
        XCTAssertEqual(trial.discoveryState, .missing)
        XCTAssertEqual(trial.evidenceState(for: trial.exchanges[0]), .missing)
        XCTAssertEqual(trial.evidenceState(for: trial.exchanges[1]), .recorded)
    }

    @MainActor
    func testResetStartsOnlyAfterSuccessAndRestartsElapsedAndPeerCounting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.recorder.resetCompleted(success: false, metadata: fixture.metadata)
        XCTAssertTrue(fixture.log.records.isEmpty)
        fixture.recorder.resetCompleted(success: true, metadata: fixture.metadata)
        let firstID = try XCTUnwrap(fixture.log.records.first).id
        let peer = PeerHandle()
        fixture.recorder.record(.peerFirstObserved(peer))
        fixture.recorder.beginIfNeeded(metadata: fixture.metadata)
        XCTAssertEqual(fixture.log.records.count, 1)
        fixture.recorder.resetCompleted(success: false, metadata: fixture.metadata)
        XCTAssertEqual(fixture.log.records.count, 1)
        XCTAssertTrue(try XCTUnwrap(fixture.log.records.first).isOpen)
        fixture.clock.seconds = 500
        fixture.recorder.resetCompleted(success: true, metadata: fixture.metadata)
        XCTAssertEqual(fixture.log.records.count, 2)
        XCTAssertFalse(fixture.log.records[0].isOpen)
        XCTAssertNotEqual(firstID, fixture.log.records[1].id)
        fixture.clock.seconds = 507
        fixture.recorder.record(.peerFirstObserved(peer))
        XCTAssertEqual(try fixture.read()[1].discoveryElapsedSeconds, 7)
        XCTAssertEqual(try fixture.read()[1].distinctPeerCount, 1)
    }

    @MainActor
    func testAttemptEndsKeepOnlyNewestFiftyAndPersistRolesAndElapsed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.recorder.beginIfNeeded(metadata: fixture.metadata)
        for index in 0..<60 {
            fixture.clock.seconds = Double(index)
            fixture.recorder.record(.attemptEnded(role: .peripheral, reason: .disconnected))
        }
        let ends = try fixture.read()[0].attemptEnds
        XCTAssertEqual(ends.count, 50)
        XCTAssertEqual(ends.first?.elapsedSeconds, 10)
        XCTAssertEqual(ends.last?.elapsedSeconds, 59)
        XCTAssertTrue(ends.allSatisfy { $0.role == .peripheral && $0.reason == "disconnected" })
    }

    @MainActor
    func testPruningOnWriteAndLoadAndRelaunchClosesPendingTrial() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let old = TrialRecord(creationDate: TrialRecord.calendarDate(fixture.wall.date.addingTimeInterval(-8 * 86400)),
                              metadata: fixture.metadata)
        let boundary = TrialRecord(creationDate: TrialRecord.calendarDate(fixture.wall.date.addingTimeInterval(-7 * 86400)),
                                   metadata: fixture.metadata)
        let recent = TrialRecord(creationDate: TrialRecord.calendarDate(fixture.wall.date), metadata: fixture.metadata)
        fixture.log.update { $0 = [old, boundary, recent] }
        XCTAssertEqual(try fixture.read().map(\.id), [boundary.id, recent.id])
        // Test a launch with an unpruned file, rather than relying on update's pruning.
        try JSONEncoder().encode([old, boundary, recent]).write(to: fixture.log.fileURL)
        let relaunched = TrialLog(fileURL: fixture.log.fileURL, now: { fixture.wall.date })
        XCTAssertEqual(relaunched.records.map(\.id), [boundary.id, recent.id])
        XCTAssertTrue(relaunched.records.allSatisfy { !$0.isOpen && $0.discoveryState == .missing })
        XCTAssertEqual(try fixture.read().map(\.id), [boundary.id, recent.id])
        fixture.wall.date = fixture.wall.date.addingTimeInterval(1)
        relaunched.update { _ in }
        XCTAssertEqual(try fixture.read().map(\.id), [recent.id])
        XCTAssertTrue(relaunched.clear())
        XCTAssertTrue(try fixture.read().isEmpty)
    }

    @MainActor
    func testEncodedLogHasOnlyApprovedKeysAndCalendarDates() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.recorder.beginIfNeeded(metadata: fixture.metadata)
        let peer = PeerHandle()
        fixture.recorder.record(.peerFirstObserved(peer))
        fixture.recorder.record(.exchangeCompleted(role: .central, nonceDigest: "digest"))
        fixture.recorder.record(.evidenceReached(role: .central, nonceDigest: "digest", observedDuration: 120))
        fixture.recorder.record(.attemptEnded(role: .central, reason: .evidenceReached))
        let data = try Data(contentsOf: fixture.log.fileURL)
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(Set(record.keys), Set(["id", "creationDate", "metadata", "isOpen", "discoveryElapsedSeconds",
            "distinctPeerCount", "exchanges", "evidence", "attemptEnds", "serverConfirmation"]))
        let metadata = try XCTUnwrap(record["metadata"] as? [String: Any])
        XCTAssertEqual(Set(metadata.keys), Set(["buildKind", "appVersion", "appBuild", "iOSVersion", "deviceModel",
            "presenceApproach", "participationEnabled", "bluetoothAvailability", "batteryLevel"]))
        let exchanges = try XCTUnwrap(record["exchanges"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(exchanges.first).keys), Set(["role", "exchangeDigest", "elapsedSeconds"]))
        let evidence = try XCTUnwrap(record["evidence"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(evidence.first).keys),
                       Set(["role", "exchangeDigest", "elapsedSeconds", "observedDurationSeconds"]))
        let ends = try XCTUnwrap(record["attemptEnds"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(ends.first).keys), Set(["role", "reason", "elapsedSeconds"]))
        XCTAssertNotNil((record["creationDate"] as? String)?.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression))
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains(peer.id.uuidString))
        XCTAssertFalse(encoded.lowercased().contains("nonce"))
        XCTAssertFalse(encoded.lowercased().contains("token"))
        XCTAssertFalse(encoded.lowercased().contains("receipt"))
        XCTAssertFalse(encoded.contains("wall"))
        XCTAssertEqual(record["serverConfirmation"] as? String, "unavailable")
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.log.fileURL.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        XCTAssertEqual(try fixture.log.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    @MainActor
    func testCorruptLogShowsErrorAndRetryDoesNotSilentlyOverwriteIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: fixture.log.fileURL)
        let log = TrialLog(fileURL: fixture.log.fileURL, now: { fixture.wall.date })
        XCTAssertEqual(log.state, .failed)
        XCTAssertFalse(log.update { $0 = [] })
        log.retry()
        XCTAssertEqual(log.state, .failed)
        XCTAssertEqual(try Data(contentsOf: log.fileURL), corrupt)
        XCTAssertTrue(log.clear())
        XCTAssertEqual(log.state, .ready)
    }

    @MainActor
    func testDemoAndPresenceApproachPersistAndDemoDoesNotChangeEvidence() throws {
        let suite = "EngineerEncounters.DiagnosticsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let demo = DemoSwitchSetting(defaults: defaults)
        let approach = PresenceApproachSetting(defaults: defaults)
        XCTAssertFalse(demo.isEnabled)
        XCTAssertEqual(approach.value, .heldConnection)
        demo.isEnabled = true
        approach.value = .secondExchange
        XCTAssertTrue(DemoSwitchSetting(defaults: defaults).isEnabled)
        XCTAssertEqual(PresenceApproachSetting(defaults: defaults).value, .secondExchange)
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.recorder.beginIfNeeded(metadata: fixture.metadata)
        fixture.recorder.record(.exchangeCompleted(role: .central, nonceDigest: "one"))
        let trial = try XCTUnwrap(fixture.log.records.first)
        XCTAssertEqual(trial.evidenceState, .pending)
        XCTAssertTrue(trial.evidence.isEmpty)
        XCTAssertEqual(trial.serverConfirmation, .unavailable)
        demo.isEnabled = false
        approach.value = .heldConnection
        XCTAssertFalse(DemoSwitchSetting(defaults: defaults).isEnabled)
        XCTAssertEqual(PresenceApproachSetting(defaults: defaults).value, .heldConnection)
    }
}

@MainActor
private final class ManualTrialClock: TrialClock { var seconds: TimeInterval = 0 }

@MainActor
private final class TrialWallClock { var date = Date(timeIntervalSince1970: 1_728_000_000) }

@MainActor
private struct Fixture {
    let directory: URL
    let clock = ManualTrialClock()
    let wall = TrialWallClock()
    let log: TrialLog
    let recorder: TrialRecorder
    let metadata = TrialMetadata(buildKind: "Development", appVersion: "0.1", appBuild: "1",
        iOSVersion: "26", deviceModel: "iPhone15,4", presenceApproach: "heldConnection",
        participationEnabled: true, bluetoothAvailability: "available", batteryLevel: 0.5)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let wall = self.wall
        log = TrialLog(fileURL: directory.appending(path: "Diagnostics/trial-log.json"), now: { wall.date })
        recorder = TrialRecorder(log: log, clock: clock, now: { wall.date })
        guard log.state == .ready else { throw CocoaError(.fileWriteUnknown) }
    }
    func read() throws -> [TrialRecord] {
        try JSONDecoder().decode([TrialRecord].self, from: Data(contentsOf: log.fileURL))
    }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
#endif
