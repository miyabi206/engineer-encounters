import XCTest
@testable import EncounterUI

final class SettingsModelTests: XCTestCase {
    @MainActor
    func testProfileSaveTrimsAllValuesAndCommitsBothStages() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        model.displayName = " 名前 "
        model.introduction = " 紹介\n"
        model.contactDetail = " mail@example.test "
        model.selectedInterestIDs = ["web"]
        model.selectedPurposes = [.collaboration]
        let saved = await model.saveProfile()
        XCTAssertTrue(saved)
        XCTAssertEqual(driver.writes, ["profile", "selections"])
        XCTAssertEqual(model.profile.displayName, "名前")
        XCTAssertEqual(model.profile.introduction, "紹介")
        XCTAssertEqual(model.profile.contactDetail, "mail@example.test")
        XCTAssertEqual(model.profile.interestIDs, ["web"])
        XCTAssertEqual(model.matchingPurposes, [.collaboration])
        XCTAssertFalse(model.hasProfileChanges)
    }

    @MainActor
    func testInvalidScalarLengthAndMissingPurposeNeverReachActions() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        model.displayName = String(repeating: "e\u{301}", count: 16)
        XCTAssertFalse(model.canSaveProfile)
        let invalidName = await model.saveProfile()
        XCTAssertFalse(invalidName)
        model.displayName = "Name"
        model.selectedPurposes = []
        let invalidPurpose = await model.saveProfile()
        XCTAssertFalse(invalidPurpose)
        XCTAssertTrue(driver.writes.isEmpty)
        model.selectedPurposes = [.discovery]
        model.contactDetail = " \n "
        XCTAssertTrue(model.canSaveProfile)
    }

    @MainActor
    func testPrerequisiteRemovalIsRefusedWhileDiscoveryIsOn() async {
        for field in [ProfileField.displayName, .introduction, .interests] {
            let driver = SettingsTestDriver()
            driver.profile.discoveryOn = true
            let model = driver.model()
            switch field {
            case .displayName: model.displayName = " \n "
            case .introduction: model.introduction = ""
            case .interests: model.toggleInterest("ios")
            default: XCTFail("Unexpected test field")
            }
            let saved = await model.saveProfile()
            XCTAssertFalse(saved)
            XCTAssertEqual(model.errors[.profile], .init(code: .prerequisiteMissing, fields: [field.rawValue]))
            XCTAssertTrue(driver.writes.isEmpty)
            XCTAssertTrue(model.profile.discoveryOn)
        }
    }

    @MainActor
    func testPartialProfileFailureRetainsInputAndRetrySkipsConfirmedWrite() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        model.displayName = " Edited "
        model.selectedInterestIDs = ["web"]
        driver.failAt = "selections"
        driver.failure = ProfileActionError(code: .invalidInput, fields: ["interest_ids"])
        let first = await model.saveProfile()
        XCTAssertFalse(first)
        XCTAssertEqual(model.displayName, " Edited ")
        XCTAssertEqual(model.selectedInterestIDs, ["web"])
        XCTAssertEqual(model.profile.displayName, "Edited")
        XCTAssertEqual(model.profile.interestIDs, ["ios"])
        XCTAssertEqual(model.errors[.profile]?.fields, ["interest_ids"])
        driver.failAt = nil
        let retry = await model.saveProfile()
        XCTAssertTrue(retry)
        XCTAssertEqual(driver.writes, ["profile", "selections", "selections"])
        XCTAssertNil(model.errors[.profile])
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testInterestLoadingFailureAndEmptyListPreserveDraftAndCanRetry() async {
        let driver = SettingsTestDriver()
        let model = driver.model(interestsLoaded: false)
        model.displayName = "Draft"
        model.selectedInterestIDs = ["web"]
        driver.failAt = "load"
        await model.loadInterests()
        XCTAssertFalse(model.hasLoadedInterests)
        XCTAssertNotNil(model.interestLoadError)
        XCTAssertEqual(model.displayName, "Draft")
        XCTAssertEqual(model.selectedInterestIDs, ["web"])
        driver.failAt = nil
        driver.options = []
        await model.loadInterests()
        XCTAssertTrue(model.hasLoadedInterests)
        XCTAssertFalse(model.canSaveProfile)
        driver.options = InterimProfileInterests.options
        await model.loadInterests()
        XCTAssertTrue(model.canSaveProfile)
        XCTAssertNil(model.interestLoadError)
    }

    @MainActor
    func testSelectionLimitAllowsDeselectionAndRejectsUnknownOption() {
        let driver = SettingsTestDriver()
        driver.options = (1...11).map { .init(id: "\($0)", labelJapanese: "項目", labelEnglish: "Item") }
        let model = driver.model()
        model.selectedInterestIDs = Set((1...10).map(String.init))
        model.toggleInterest("11")
        model.toggleInterest("unknown")
        XCTAssertEqual(model.selectedInterestIDs.count, 10)
        model.toggleInterest("1")
        model.toggleInterest("11")
        XCTAssertTrue(model.selectedInterestIDs.contains("11"))
        XCTAssertFalse(model.selectedInterestIDs.contains("1"))
    }

    @MainActor
    func testDiscoveryCannotActivateInUnit3AndNeedsAllPrerequisitesAndBluetooth() async {
        let driver = SettingsTestDriver()
        driver.profile.prerequisites.link = true
        let unit3 = driver.model()
        XCTAssertFalse(unit3.canEnableDiscovery)
        await unit3.setDiscovery(true)
        XCTAssertTrue(driver.writes.isEmpty)
        let later = driver.model(allowsActivation: true)
        XCTAssertTrue(later.canEnableDiscovery)
        await later.setDiscovery(true)
        XCTAssertTrue(later.profile.discoveryOn)
        XCTAssertEqual(driver.writes, ["discovery"])
        driver.profile.discoveryOn = false
        driver.profile.prerequisites.link = false
        let missingLink = driver.model(allowsActivation: true)
        XCTAssertFalse(missingLink.canEnableDiscovery)
        let unavailable = driver.model(allowsActivation: true, bluetooth: .poweredOff)
        XCTAssertFalse(unavailable.canEnableDiscovery)
    }

    @MainActor
    func testFailedDiscoveryRestoresConfirmedSwitchAndRetrySucceeds() async {
        let driver = SettingsTestDriver()
        driver.profile.discoveryOn = true
        let model = driver.model()
        driver.failAt = "discovery"
        await model.setDiscovery(false)
        XCTAssertTrue(model.profile.discoveryOn)
        XCTAssertNotNil(model.errors[.discovery])
        driver.failAt = nil
        await model.setDiscovery(false)
        XCTAssertFalse(model.profile.discoveryOn)
        XCTAssertNil(model.errors[.discovery])
        XCTAssertEqual(driver.writes, ["discovery", "discovery"])
    }

    @MainActor
    func testMatchingBoundsPartialSaveAndDraftPreservation() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        for invalid in [0, 11] {
            model.minimumSharedInterests = invalid
            await model.saveMatching()
            XCTAssertFalse(model.canSaveMatching)
        }
        XCTAssertTrue(driver.writes.isEmpty)
        model.minimumSharedInterests = 10
        model.matchingPurposes = []
        await model.saveMatching()
        XCTAssertTrue(driver.writes.isEmpty)
        model.matchingPurposes = [.collaboration]
        model.selectedPurposes = [.discovery, .collaboration] // An independent unsaved S12 draft.
        driver.failAt = "threshold"
        await model.saveMatching()
        XCTAssertEqual(model.profile.purposes, [.collaboration])
        XCTAssertEqual(model.profile.minimumSharedInterests, 1)
        XCTAssertEqual(model.minimumSharedInterests, 10)
        XCTAssertEqual(model.selectedPurposes, [.discovery, .collaboration])
        driver.failAt = nil
        await model.saveMatching()
        XCTAssertEqual(driver.writes, ["selections", "threshold", "threshold"])
        XCTAssertEqual(model.profile.minimumSharedInterests, 10)
        XCTAssertFalse(model.hasMatchingChanges)
    }

    @MainActor
    func testVisibilityPartialFailureMapsFieldAndPreservesS12Draft() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        model.displayName = "Unsaved name"
        model.visibility[.displayName] = .private
        model.visibility[.introduction] = .compatibleOnly
        driver.failAt = "visibility:introduction"
        driver.failure = ProfileActionError(code: .invalidInput, fields: ["level"])
        await model.saveVisibility()
        XCTAssertEqual(model.profile.fieldVisibility[.displayName], .private)
        XCTAssertEqual(model.profile.fieldVisibility[.introduction], .everyoneEligible)
        XCTAssertEqual(model.visibility[.introduction], .compatibleOnly)
        XCTAssertEqual(model.errors[.visibility]?.fields, ["introduction"])
        XCTAssertEqual(model.displayName, "Unsaved name")
        XCTAssertEqual(model.visibility[.contactDetail], .private)
        driver.failAt = nil
        await model.saveVisibility()
        XCTAssertEqual(driver.writes, ["visibility:display_name", "visibility:introduction", "visibility:introduction"])
        XCTAssertNil(model.errors[.visibility])
        XCTAssertFalse(model.hasVisibilityChanges)
        XCTAssertTrue(model.hasProfileChanges)
        model.discard(.profile)
        XCTAssertFalse(model.hasProfileChanges)
        XCTAssertEqual(model.profile.fieldVisibility[.displayName], .private)
    }

    @MainActor
    func testBusyStatePreventsDuplicateWritesAndDiscard() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        model.displayName = "Draft"
        driver.duringProfileSave = {
            XCTAssertTrue(model.isBusy)
            XCTAssertFalse(model.canSaveProfile)
            model.discard(.profile)
            model.toggleInterest("web")
            let duplicate = await model.saveProfile()
            XCTAssertFalse(duplicate)
            await model.saveMatching()
            await model.saveVisibility()
            await model.setDiscovery(false)
            XCTAssertEqual(model.displayName, "Draft")
        }
        let saved = await model.saveProfile()
        XCTAssertTrue(saved)
        XCTAssertEqual(driver.writes, ["profile"])
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testCancellationAndBluetoothDenialDoNotChangeDiscovery() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        model.displayName = "Draft"
        driver.failAt = "profile"
        driver.failure = CancellationError()
        let saved = await model.saveProfile()
        XCTAssertFalse(saved)
        XCTAssertNil(model.errors[.profile])
        XCTAssertEqual(model.displayName, "Draft")
        XCTAssertFalse(model.isBusy)
        driver.failAt = nil
        driver.permission = .denied
        await model.requestBluetooth()
        XCTAssertEqual(model.bluetooth, .denied)
        XCTAssertFalse(model.profile.discoveryOn)
        XCTAssertFalse(model.canEnableDiscovery)
    }
}

@MainActor
private final class SettingsTestDriver {
    var profile = OwnProfileState(displayName: "Name", introduction: "Introduction", interestIDs: ["ios"], purposes: [.discovery],
                                  prerequisites: .init(displayName: true, introduction: true, interest: true))
    var options = InterimProfileInterests.options
    var writes: [String] = []
    var failAt: String?
    var failure: any Error = ProfileActionError(code: .unavailable)
    var permission = BluetoothPermissionState.available
    var duringProfileSave: (@MainActor () async -> Void)?

    func model(interestsLoaded: Bool = true, allowsActivation: Bool = false,
               bluetooth: BluetoothPermissionState = .available) -> SettingsModel {
        SettingsModel(profile: profile, actions: actions, interests: interestsLoaded ? options : nil,
                      bluetooth: bluetooth, allowsDiscoveryActivation: allowsActivation)
    }

    private func attempt(_ operation: String) throws {
        writes.append(operation)
        if failAt == operation { throw failure }
    }

    private var actions: ProfileActions {
        ProfileActions(loadInterests: {
            try self.attempt("load")
            return self.options
        }, saveProfile: { name, intro, contact in
            await self.duringProfileSave?()
            try self.attempt("profile")
            self.profile.displayName = name; self.profile.introduction = intro; self.profile.contactDetail = contact
            self.profile.prerequisites.displayName = !name.isEmpty
            self.profile.prerequisites.introduction = !intro.isEmpty
            return self.profile
        }, saveInterestsAndPurposes: { interests, purposes in
            try self.attempt("selections")
            self.profile.interestIDs = interests; self.profile.purposes = purposes
            self.profile.prerequisites.interest = !interests.isEmpty
            return self.profile
        }, setDiscovery: { enabled in
            try self.attempt("discovery")
            self.profile.discoveryOn = enabled
            return self.profile
        }, requestBluetooth: {
            try self.attempt("bluetooth")
            return self.permission
        }, setMinimumSharedInterests: { value in
            try self.attempt("threshold")
            self.profile.minimumSharedInterests = value
            return self.profile
        }, setFieldVisibility: { field, level in
            try self.attempt("visibility:" + field.rawValue)
            self.profile.fieldVisibility[field] = level
            return self.profile
        })
    }
}
