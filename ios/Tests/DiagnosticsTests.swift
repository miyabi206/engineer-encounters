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
    func testEntryCapsKeepEarliestMeasurementsAndPersistIndependentOverflowCounts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.recorder.beginIfNeeded(metadata: fixture.metadata)
        for index in 0..<200 {
            fixture.clock.seconds = Double(index)
            fixture.recorder.record(.exchangeCompleted(role: .central, nonceDigest: "exchange-\(index)"))
            fixture.recorder.record(.evidenceReached(role: .peripheral, nonceDigest: "evidence-\(index)", observedDuration: 120))
        }
        let full = try fixture.read()[0]
        XCTAssertEqual(full.exchanges.count, 200)
        XCTAssertEqual(full.evidence.count, 200)
        XCTAssertEqual(full.droppedExchangeCount, 0)
        XCTAssertEqual(full.droppedEvidenceCount, 0)
        fixture.clock.seconds = 200
        fixture.recorder.record(.exchangeCompleted(role: .central, nonceDigest: "overflow"))
        XCTAssertEqual(try fixture.read()[0].droppedExchangeCount, 1)
        XCTAssertEqual(try fixture.read()[0].droppedEvidenceCount, 0)
        for index in 0..<9 {
            fixture.clock.seconds = Double(201 + index)
            if index < 4 {
                fixture.recorder.record(.exchangeCompleted(role: .central, nonceDigest: "overflow-\(index)"))
            }
            fixture.recorder.record(.evidenceReached(role: .peripheral, nonceDigest: "overflow-\(index)", observedDuration: 120))
        }
        let trial = try fixture.read()[0]
        XCTAssertEqual(trial.exchanges, full.exchanges)
        XCTAssertEqual(trial.evidence, full.evidence)
        XCTAssertEqual(trial.exchanges.first?.exchangeDigest, "exchange-0")
        XCTAssertEqual(trial.evidence.first?.exchangeDigest, "evidence-0")
        XCTAssertEqual(trial.exchanges.first?.elapsedSeconds, 0)
        XCTAssertEqual(trial.evidence.first?.elapsedSeconds, 0)
        XCTAssertEqual(trial.droppedExchangeCount, 5)
        XCTAssertEqual(trial.droppedEvidenceCount, 9)
        XCTAssertEqual(fixture.log.records.first, trial)
        let relaunched = TrialLog(fileURL: fixture.log.fileURL, now: { fixture.wall.date })
        XCTAssertEqual(relaunched.records[0].droppedExchangeCount, 5)
        XCTAssertEqual(relaunched.records[0].droppedEvidenceCount, 9)
        XCTAssertEqual(relaunched.records[0].exchanges, full.exchanges)
        XCTAssertEqual(relaunched.records[0].evidence, full.evidence)
    }

    @MainActor
    func testRecordCapDropsOldestClosedTrialsAndPreservesOpenTrialAndOrdinal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let trials = (1...206).map { ordinal in
            TrialRecord(ordinal: ordinal, creationDate: TrialRecord.calendarDate(fixture.wall.date),
                        metadata: fixture.metadata, isOpen: ordinal == 1)
        }
        XCTAssertTrue(fixture.log.update { $0 = trials })
        let kept = try fixture.read()
        XCTAssertEqual(kept.count, 200)
        XCTAssertEqual(kept.map(\.ordinal), [1] + Array(8...206))
        XCTAssertEqual(kept.first?.id, trials[0].id)
        XCTAssertEqual(kept.filter(\.isOpen).map(\.id), [trials[0].id])
        XCTAssertEqual(fixture.log.records, kept)
        // Starting a new trial closes the previously protected one and makes
        // it the oldest eligible record, without reusing a dropped ordinal.
        fixture.recorder.beginIfNeeded(metadata: fixture.metadata)
        XCTAssertEqual(try fixture.read().map(\.ordinal), Array(8...207))
        XCTAssertEqual(try fixture.read().filter(\.isOpen).map(\.ordinal), [207])
    }

    @MainActor
    func testLegacyLogLoadsWithoutCountersAndCapsOversizedEntriesAndRecords() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var trials = (1...205).map { ordinal in
            TrialRecord(ordinal: ordinal, creationDate: TrialRecord.calendarDate(fixture.wall.date),
                        metadata: fixture.metadata)
        }
        trials[204].exchanges = (0..<203).map {
            TrialExchange(role: .central, exchangeDigest: "exchange-\($0)", elapsedSeconds: Double($0))
        }
        trials[204].evidence = (0..<204).map {
            TrialEvidence(role: .peripheral, exchangeDigest: "evidence-\($0)",
                          elapsedSeconds: Double($0), observedDurationSeconds: 120)
        }
        let encoded = try JSONEncoder().encode(trials)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for index in legacy.indices {
            legacy[index].removeValue(forKey: "droppedExchangeCount")
            legacy[index].removeValue(forKey: "droppedEvidenceCount")
        }
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode([TrialRecord].self, from: data)
        XCTAssertTrue(decoded.allSatisfy { $0.droppedExchangeCount == 0 && $0.droppedEvidenceCount == 0 })
        try data.write(to: fixture.log.fileURL)
        let relaunched = TrialLog(fileURL: fixture.log.fileURL, now: { fixture.wall.date })
        XCTAssertEqual(relaunched.state, .ready)
        XCTAssertEqual(relaunched.records.map(\.ordinal), Array(6...205))
        XCTAssertEqual(relaunched.nextOrdinal, 206)
        XCTAssertTrue(relaunched.records.allSatisfy { !$0.isOpen })
        let capped = try XCTUnwrap(relaunched.records.last)
        XCTAssertEqual(capped.exchanges, Array(trials[204].exchanges.prefix(200)))
        XCTAssertEqual(capped.evidence, Array(trials[204].evidence.prefix(200)))
        XCTAssertEqual(capped.droppedExchangeCount, 3)
        XCTAssertEqual(capped.droppedEvidenceCount, 4)
        XCTAssertEqual(try fixture.read(), relaunched.records)
        XCTAssertTrue(relaunched.prune())
        XCTAssertEqual(try fixture.read().last?.droppedExchangeCount, 3)
        XCTAssertEqual(try fixture.read().last?.droppedEvidenceCount, 4)
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
        XCTAssertEqual(try fixture.read().map(\.id), [recent.id])
        // Test a launch with an unpruned file, rather than relying on update's pruning.
        try JSONEncoder().encode([old, boundary, recent]).write(to: fixture.log.fileURL)
        let relaunched = TrialLog(fileURL: fixture.log.fileURL, now: { fixture.wall.date })
        XCTAssertEqual(relaunched.records.map(\.id), [recent.id])
        XCTAssertTrue(relaunched.records.allSatisfy { !$0.isOpen && $0.discoveryState == .missing })
        XCTAssertEqual(try fixture.read().map(\.id), [recent.id])
        fixture.wall.date = fixture.wall.date.addingTimeInterval(7 * 86400)
        relaunched.update { _ in }
        XCTAssertTrue(try fixture.read().isEmpty)
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
        XCTAssertEqual(Set(record.keys), Set(["id", "ordinal", "startReason", "presenceApproachChanged", "creationDate", "metadata", "isOpen", "discoveryElapsedSeconds",
            "distinctPeerCount", "exchanges", "evidence", "droppedExchangeCount", "droppedEvidenceCount", "attemptEnds", "serverConfirmation"]))
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
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.log.fileURL.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif
        XCTAssertEqual(try fixture.log.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    @MainActor
    func testCorruptLogRetryMovesUnreadableFileAsideAndClearDeletesIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: fixture.log.fileURL)
        let log = TrialLog(fileURL: fixture.log.fileURL, now: { fixture.wall.date })
        XCTAssertEqual(log.state, .failed)
        XCTAssertFalse(log.update { $0 = [] })
        log.retry()
        XCTAssertEqual(log.state, .ready)
        XCTAssertTrue(log.records.isEmpty)
        let directory = log.fileURL.deletingLastPathComponent()
        let moved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains(".unreadable-") })
        XCTAssertEqual(try Data(contentsOf: moved), corrupt)
        XCTAssertTrue(log.update { $0.append(TrialRecord(creationDate: TrialRecord.calendarDate(fixture.wall.date), metadata: fixture.metadata)) })
        XCTAssertTrue(log.clear())
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertEqual(log.state, .ready)
    }

    @MainActor
    func testOrdinalAndStartReasonSurviveResetSwitchAndLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.recorder.beginIfNeeded(metadata: fixture.metadata, reason: .participationSwitch)
        XCTAssertTrue(fixture.recorder.resetCompleted(success: true, metadata: fixture.metadata))
        fixture.recorder.close()
        fixture.recorder.beginIfNeeded(metadata: fixture.metadata, reason: .participationSwitch)
        let relaunchedLog = TrialLog(fileURL: fixture.log.fileURL, now: { fixture.wall.date })
        let relaunched = TrialRecorder(log: relaunchedLog, clock: fixture.clock, now: { fixture.wall.date })
        relaunched.beginIfNeeded(metadata: fixture.metadata, reason: .launch)
        let records = try fixture.read()
        XCTAssertEqual(records.map(\.ordinal), [1, 2, 3, 4])
        XCTAssertEqual(records.map(\.startReason), [.participationSwitch, .reset, .participationSwitch, .launch])
        XCTAssertEqual(records.map(\.isOpen), [false, false, false, true])
    }

    @MainActor
    func testCalendarDateAndRetentionUseDeviceLocalDay() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let time = Date(timeIntervalSince1970: 1_728_060_000) // 16:40 UTC, next day in Japan.
        XCTAssertEqual(TrialRecord.calendarDate(time, timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))), "2024-10-05")
        XCTAssertEqual(TrialRecord.calendarDate(time, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))), "2024-10-04")
        fixture.wall.date = time
        fixture.recorder.beginIfNeeded(metadata: fixture.metadata)
        let record = try XCTUnwrap(fixture.log.records.first)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(record.creationDate, formatter.string(from: time))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        XCTAssertEqual(record.retentionDate, calendar.startOfDay(for: time))
    }

    @MainActor
    func testDefaultRecorderClockIsContinuous() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let recorder = TrialRecorder(log: fixture.log)
        XCTAssertTrue(recorder.clock is ContinuousTrialClock)
        XCTAssertGreaterThanOrEqual(recorder.clock.seconds, 0)
    }

    @MainActor
    func testApproachChangeIsFlaggedAndFirstKnownRadioAvailabilityIsStored() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var metadata = fixture.metadata
        metadata.bluetoothAvailability = "unknown"
        fixture.recorder.beginIfNeeded(metadata: metadata)
        fixture.recorder.selectPresenceApproach(.heldConnection)
        XCTAssertFalse(try fixture.read()[0].presenceApproachChanged)
        fixture.recorder.selectPresenceApproach(.secondExchange)
        fixture.recorder.selectPresenceApproach(.heldConnection)
        fixture.recorder.record(.radioAvailability(.unknown))
        fixture.recorder.record(.radioAvailability(.available))
        fixture.recorder.record(.radioAvailability(.unavailable))
        let record = try fixture.read()[0]
        XCTAssertTrue(record.presenceApproachChanged)
        XCTAssertEqual(record.metadata.presenceApproach, "heldConnection")
        XCTAssertEqual(record.metadata.bluetoothAvailability, "available")
    }

    @MainActor
    func testWriteFailureKeepsRecordingAndNextWritePersistsWholeTrial() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.log.fileURL)
        try FileManager.default.createDirectory(at: fixture.log.fileURL, withIntermediateDirectories: false)
        // Even the first trial write can fail: keep its clock and in-memory identity.
        fixture.recorder.beginIfNeeded(metadata: fixture.metadata)
        XCTAssertEqual(fixture.log.state, .failed)
        fixture.clock.seconds = 3
        fixture.recorder.record(.peerFirstObserved(PeerHandle()))
        fixture.clock.seconds = 5
        fixture.recorder.record(.exchangeCompleted(role: .central, nonceDigest: "digest"))
        try FileManager.default.removeItem(at: fixture.log.fileURL)
        fixture.clock.seconds = 125
        fixture.recorder.record(.evidenceReached(role: .central, nonceDigest: "digest", observedDuration: 120))
        XCTAssertEqual(fixture.log.state, .ready)
        let record = try fixture.read()[0]
        XCTAssertEqual(record.discoveryElapsedSeconds, 3)
        XCTAssertEqual(record.exchanges.first?.elapsedSeconds, 5)
        XCTAssertEqual(record.evidence.first?.elapsedSeconds, 125)
    }

    @MainActor
    func testUnreadableBackupIsPrunedAfterSevenDays() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try Data("invalid".utf8).write(to: fixture.log.fileURL)
        let log = TrialLog(fileURL: fixture.log.fileURL, now: { fixture.wall.date })
        log.retry()
        let directory = log.fileURL.deletingLastPathComponent()
        let moved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains(".unreadable-") })
        fixture.wall.date = fixture.wall.date.addingTimeInterval(7 * 86400 + 1)
        XCTAssertTrue(log.prune())
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
    }

    func testJapaneseAndEnglishTablesResolveDocumentedLabels() throws {
        let bundle = Bundle.main
        let jaPath = try XCTUnwrap(bundle.path(forResource: "ja", ofType: "lproj"))
        let enPath = try XCTUnwrap(bundle.path(forResource: "en", ofType: "lproj"))
        let ja = try XCTUnwrap(Bundle(path: jaPath))
        let en = try XCTUnwrap(Bundle(path: enPath))
        for (key, japanese, english) in [
            ("title", "診断", "Diagnostics"),
            ("reset", "試行をリセット", "Reset trial"),
            ("approach", "存在確認の方式", "Presence approach"),
            ("share", "試行ログを共有", "Share trial log"),
            ("attemptReset", "リセットによる終了", "Ended by reset"),
            ("startLaunch", "アプリ起動", "App launch"),
            ("droppedExchangeCount", "上限を超えて記録しなかった交換の数", "Exchange entries dropped beyond limit"),
            ("droppedEvidenceCount", "上限を超えて記録しなかった証拠の数", "Evidence entries dropped beyond limit")
        ] {
            XCTAssertEqual(ja.localizedString(forKey: key, value: nil, table: "Diagnostics"), japanese)
            XCTAssertEqual(en.localizedString(forKey: key, value: nil, table: "Diagnostics"), english)
        }
        #if DEVELOPMENT_BUILD
        XCTAssertEqual(ja.localizedString(forKey: "diagnostics", value: nil, table: "DevelopmentDiagnostics"), "診断")
        XCTAssertEqual(en.localizedString(forKey: "diagnostics", value: nil, table: "DevelopmentDiagnostics"), "Diagnostics")
        #endif
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
private final class TrialWallClock {
    // Deliberately away from midnight: retention uses the local calendar day.
    var date = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_728_000_000))
        .addingTimeInterval(12 * 3600)
}

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
