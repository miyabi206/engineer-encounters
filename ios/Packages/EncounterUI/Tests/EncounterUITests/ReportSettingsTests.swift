import XCTest
@testable import EncounterUI

final class ReportSettingsTests: XCTestCase {
    func testTimeBoundsAndDefault() {
        XCTAssertEqual(ReportSettingsTime(), .init(hour: 21, minute: 0))
        for hour in [-1, 0, 23, 24] {
            for minute in [-1, 0, 59, 60] {
                XCTAssertEqual(ReportSettingsTime(hour: hour, minute: minute).isValid,
                               (0...23).contains(hour) && (0...59).contains(minute))
            }
        }
    }

    @MainActor
    func testUnavailablePushOmitsAllNotificationActions() async {
        let driver = ReportSettingsTestDriver()
        let model = driver.model(pushAvailable: false)
        XCTAssertFalse(model.showsNotificationSwitch)
        await model.setNotifications(true); await model.setNotifications(false)
        XCTAssertTrue(driver.calls.isEmpty)
        XCTAssertFalse(model.data?.notificationsEnabled ?? true)
    }

    @MainActor
    func testNotificationSwitchRequiresAvailablePushAndChangeablePermission() async {
        for pushAvailable in [false, true] {
            for permission in [ReportSettingsPermission.notRequested, .allowed, .denied, .unavailable] {
                let driver = ReportSettingsTestDriver()
                let model = driver.model(pushAvailable: pushAvailable)
                model.receive(permission: permission)
                let expected = pushAvailable && (permission == .notRequested || permission == .allowed)
                XCTAssertEqual(model.showsNotificationSwitch, expected)
                if !expected {
                    await model.setNotifications(true); await model.setNotifications(false)
                    XCTAssertTrue(driver.calls.isEmpty)
                    XCTAssertEqual(model.permission, permission)
                    XCTAssertEqual(model.data?.notificationsEnabled, false)
                }
            }
        }
    }

    @MainActor
    func testUndeterminedPermissionIsRequestedOnceAndDeniedDoesNotWriteOrPromptAgain() async {
        let driver = ReportSettingsTestDriver()
        driver.permission = .denied
        let model = driver.model()
        await model.setNotifications(true); await model.setNotifications(true)
        XCTAssertEqual(driver.calls, ["permission"])
        XCTAssertEqual(model.permission, .denied)
        XCTAssertFalse(model.showsNotificationSwitch)
        XCTAssertNil(model.error)
        model.receive(permission: .allowed)
        XCTAssertTrue(model.showsNotificationSwitch)
        await model.setNotifications(true)
        XCTAssertEqual(driver.calls, ["permission", "notifications:true"])
        XCTAssertEqual(model.data?.notificationsEnabled, true)
    }

    @MainActor
    func testAllowedPermissionAndNotificationWritesPreserveTimeDraftAndRevealSettings() async {
        let driver = ReportSettingsTestDriver()
        let model = driver.model()
        model.time = .init(hour: 9, minute: 15)
        await model.setNotifications(true)
        await model.setNotifications(false)
        XCTAssertEqual(driver.calls, ["permission", "notifications:true", "notifications:false"])
        XCTAssertEqual(model.time, .init(hour: 9, minute: 15))
        XCTAssertEqual(model.data?.time, .init())
        XCTAssertEqual(model.data?.timeZone, "Asia/Tokyo")
        XCTAssertFalse(model.data?.notificationsEnabled ?? true)
    }

    @MainActor
    func testFailedSaveRetainsDraftAndRetryRequiresConfirmedTime() async {
        let driver = ReportSettingsTestDriver()
        let model = driver.model()
        model.time = .init(hour: 8, minute: 45)
        driver.fail = true
        await model.save()
        XCTAssertEqual(model.failedOperation, .time)
        XCTAssertEqual(model.time, .init(hour: 8, minute: 45)); XCTAssertFalse(model.savedTime)
        driver.fail = false
        await model.retry()
        XCTAssertEqual(model.data?.time, .init(hour: 8, minute: 45))
        XCTAssertTrue(model.savedTime); XCTAssertNil(model.error)
        model.time = .init(hour: 24, minute: 0)
        XCTAssertFalse(model.savedTime)
        await model.save()
        XCTAssertEqual(driver.calls, ["time", "time"])
        XCTAssertFalse(model.canSave)
    }

    @MainActor
    func testLoadFailureAndDuplicateWriteAndBackDuringPending() async {
        let driver = ReportSettingsTestDriver()
        let model = driver.model()
        driver.fail = true
        await model.load()
        XCTAssertNil(model.data); XCTAssertEqual(model.failedOperation, .load)
        driver.fail = false
        await model.retry()
        model.time = .init(hour: 7, minute: 30)
        driver.duringTime = {
            XCTAssertTrue(model.isBusy)
            await model.save(); await model.setNotifications(true); model.back()
        }
        await model.save()
        XCTAssertEqual(driver.calls, ["load", "load", "time"])
        XCTAssertEqual(driver.backs, 0)
        model.back(); XCTAssertEqual(driver.backs, 1)
    }
}

@MainActor
private final class ReportSettingsTestDriver {
    var data = ReportSettingsData(timeZone: "Asia/Tokyo")
    var permission = ReportSettingsPermission.allowed
    var calls: [String] = []
    var fail = false
    var backs = 0
    var duringTime: (@MainActor () async -> Void)?
    func model(pushAvailable: Bool = true) -> ReportSettingsModel {
        ReportSettingsModel(data: data, pushAvailable: pushAvailable, actions: .init(load: {
            self.calls.append("load"); try self.check(); return self.data
        }, saveTime: { time in
            self.calls.append("time"); await self.duringTime?(); try self.check()
            self.data.time = time; return self.data
        }, setNotifications: { enabled in
            self.calls.append("notifications:\(enabled)"); try self.check()
            self.data.notificationsEnabled = enabled; return self.data
        }, requestPermission: {
            self.calls.append("permission"); return self.permission
        }), navigation: .init(back: { self.backs += 1 }, systemSettings: {}))
    }
    private func check() throws { if fail { throw ProfileActionError(code: .unavailable) } }
}

final class ReportSettingsStringsTests: XCTestCase {
    func testBothLanguagesDefineEveryKey() throws {
        for language in ["ja", "en"] {
            let table = try ReportSettingsStrings.table(language: language)
            XCTAssertEqual(Set(table.keys), Set(ReportSettingsString.allCases.map(\.rawValue)))
            for key in ReportSettingsString.allCases {
                let value = try XCTUnwrap(table[key.rawValue]); XCTAssertFalse(value.isEmpty)
                XCTAssertEqual(ReportSettingsStrings.localized(key.rawValue, language: language), value)
            }
        }
        XCTAssertEqual(ReportSettingsStrings.localized("saveTime", language: "en"), "Save report time")
        XCTAssertEqual(ReportSettingsStrings.localized("ambient", language: "en"),
                       "Ambient encounters appear together at report time.")
    }
}
