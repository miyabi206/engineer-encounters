import XCTest
@testable import EncounterUI

final class OnboardingModelTests: XCTestCase {
    @MainActor
    func testSuccessfulFlowSkipsS04AndFinishesOffDespiteMissingLink() async {
        let driver = OnboardingTestDriver()
        let model = driver.model()
        XCTAssertEqual(model.step, .basics)
        XCTAssertFalse(model.canContinueBasics)
        model.displayName = " 名前 "
        model.introduction = " 紹介 "
        await model.saveBasics()
        XCTAssertEqual(driver.savedName, "名前")
        XCTAssertEqual(model.step, .interests)
        XCTAssertTrue(model.selectedPurposes.isEmpty)
        await model.loadInterests()
        model.toggleInterest("caller")
        model.togglePurpose(.collaboration)
        await model.saveSelections()
        XCTAssertEqual(model.step, .permissions)
        XCTAssertEqual(model.profile.prerequisites.missing, [.link])
        XCTAssertFalse(model.canEnableDiscovery)
        await model.finish(discovery: true)
        XCTAssertTrue(driver.discoveryWrites.isEmpty)
        await model.finish(discovery: false)
        XCTAssertEqual(driver.discoveryWrites, [false])
        XCTAssertEqual(driver.finishes, [false])
        XCTAssertFalse(model.profile.discoveryOn)
    }

    @MainActor
    func testFailedBasicsSaveRetainsInputAndRetryAdvancesOnlyOnSuccess() async {
        let driver = OnboardingTestDriver()
        driver.failure = ProfileActionError(code: .invalidInput, fields: ["display_name"])
        let model = driver.model()
        model.displayName = " 入力した名前 "
        model.introduction = "入力した紹介"
        await model.saveBasics()
        XCTAssertEqual(model.step, .basics)
        XCTAssertEqual(model.displayName, " 入力した名前 ")
        XCTAssertEqual(model.introduction, "入力した紹介")
        XCTAssertEqual(model.profile.displayName, "")
        XCTAssertEqual(model.actionError?.fields, ["display_name"])
        XCTAssertFalse(model.isBusy)
        driver.failure = nil
        await model.saveBasics()
        XCTAssertEqual(model.step, .interests)
        XCTAssertNil(model.actionError)
        model.back()
        XCTAssertEqual(model.displayName, " 入力した名前 ")
    }

    @MainActor
    func testListFailureAndSaveFailurePreserveSelections() async {
        let driver = OnboardingTestDriver()
        driver.profile.displayName = "名前"
        driver.profile.introduction = "紹介"
        driver.profile.interestIDs = ["caller"]
        let model = driver.model()
        driver.failure = ProfileActionError(code: .unavailable)
        await model.loadInterests()
        XCTAssertNotNil(model.interestLoadError)
        XCTAssertEqual(model.selectedInterestIDs, ["caller"])
        XCTAssertFalse(model.canContinueInterests)
        driver.failure = nil
        await model.loadInterests()
        XCTAssertNil(model.interestLoadError)
        model.togglePurpose(.discovery)
        driver.failure = ProfileActionError(code: .invalidInput, fields: ["purposes"])
        await model.saveSelections()
        XCTAssertEqual(model.step, .interests)
        XCTAssertEqual(model.selectedPurposes, [.discovery])
        XCTAssertEqual(model.selectedInterestIDs, ["caller"])
        XCTAssertEqual(model.actionError?.fields, ["purposes"])
        driver.failure = nil
        await model.saveSelections()
        XCTAssertEqual(model.step, .permissions)
    }

    @MainActor
    func testDuplicateWritesAndBackAreDisabledDuringSave() async {
        let driver = OnboardingTestDriver()
        let model = driver.model()
        model.displayName = "名前"
        model.introduction = "紹介"
        driver.duringSave = {
            XCTAssertTrue(model.isBusy)
            XCTAssertFalse(model.canContinueBasics)
            model.back()
            await model.saveBasics()
            XCTAssertEqual(model.step, .basics)
        }
        await model.saveBasics()
        XCTAssertEqual(driver.basicWrites, 1)
        XCTAssertEqual(driver.exits, 0)
        XCTAssertEqual(model.step, .interests)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testBluetoothDenialCallsRecoveryAndDoesNotEnableDiscovery() async {
        let driver = OnboardingTestDriver()
        driver.permission = .denied
        let model = driver.model()
        await model.requestBluetooth()
        XCTAssertEqual(model.bluetooth, .denied)
        XCTAssertEqual(driver.recoveries, 1)
        XCTAssertFalse(model.canEnableDiscovery)
        XCTAssertTrue(driver.discoveryWrites.isEmpty)
        model.recoverBluetooth()
        XCTAssertEqual(driver.recoveries, 2)
    }

    @MainActor
    func testActivationFailureDoesNotFinishOrChangeDiscoveryAndRetrySucceeds() async {
        let driver = OnboardingTestDriver()
        driver.profile.prerequisites = .init(displayName: true, introduction: true, interest: true, link: true)
        let model = driver.model(bluetooth: .available)
        driver.failure = ProfileActionError(code: .prerequisiteMissing, fields: ["link"])
        await model.finish(discovery: true)
        XCTAssertFalse(model.profile.discoveryOn)
        XCTAssertTrue(driver.finishes.isEmpty)
        XCTAssertEqual(model.actionError?.fields, ["link"])
        driver.failure = nil
        await model.finish(discovery: true)
        XCTAssertTrue(model.profile.discoveryOn)
        XCTAssertEqual(driver.finishes, [true])
    }

    @MainActor
    func testCancelledSaveShowsNoErrorAndRetainsInput() async {
        let driver = OnboardingTestDriver()
        driver.failure = CancellationError()
        let model = driver.model()
        model.displayName = "名前"
        model.introduction = "紹介"
        await model.saveBasics()
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.step, .basics)
        XCTAssertEqual(model.displayName, "名前")
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testUnknownSelectedInterestCannotPassAndLimitStillAllowsDeselection() {
        let driver = OnboardingTestDriver()
        driver.options = (1...11).map { InterestOption(id: "\($0)", labelJapanese: "項目", labelEnglish: "Item") }
        let model = driver.model(interests: driver.options)
        model.selectedInterestIDs = Set((1...10).map(String.init))
        model.selectedPurposes = [.discovery]
        model.toggleInterest("11")
        XCTAssertEqual(model.selectedInterestIDs.count, 10)
        model.toggleInterest("1")
        model.toggleInterest("11")
        XCTAssertTrue(model.selectedInterestIDs.contains("11"))
        model.selectedInterestIDs = ["unknown"]
        XCTAssertFalse(model.canContinueInterests)
    }
}

@MainActor
private final class OnboardingTestDriver {
    var profile = OwnProfileState()
    var options = [InterestOption(id: "caller", labelJapanese: "選択肢", labelEnglish: "Option")]
    var permission = BluetoothPermissionState.available
    var failure: (any Error)?
    var savedName: String?
    var basicWrites = 0
    var discoveryWrites: [Bool] = []
    var finishes: [Bool] = []
    var exits = 0
    var recoveries = 0
    var duringSave: (@MainActor () async -> Void)?

    func model(interests: [InterestOption]? = nil,
               bluetooth: BluetoothPermissionState = .notRequested) -> OnboardingModel {
        OnboardingModel(profile: profile, interests: interests, bluetooth: bluetooth, actions: actions,
                        onExit: { self.exits += 1 }, onFinish: { self.finishes.append($0) },
                        onBluetoothRecovery: { self.recoveries += 1 })
    }

    private var actions: ProfileActions {
        ProfileActions(loadInterests: {
            if let failure = self.failure { throw failure }
            return self.options
        }, saveProfile: { name, introduction, contact in
            self.basicWrites += 1
            await self.duringSave?()
            if let failure = self.failure { throw failure }
            self.savedName = name
            self.profile.displayName = name
            self.profile.introduction = introduction
            self.profile.contactDetail = contact
            self.profile.prerequisites.displayName = !name.isEmpty
            self.profile.prerequisites.introduction = !introduction.isEmpty
            return self.profile
        }, saveInterestsAndPurposes: { interests, purposes in
            if let failure = self.failure { throw failure }
            self.profile.interestIDs = interests
            self.profile.purposes = purposes
            self.profile.prerequisites.interest = !interests.isEmpty
            return self.profile
        }, setDiscovery: { enabled in
            self.discoveryWrites.append(enabled)
            if let failure = self.failure { throw failure }
            self.profile.discoveryOn = enabled
            return self.profile
        }, requestBluetooth: {
            if let failure = self.failure { throw failure }
            return self.permission
        }, setMinimumSharedInterests: { value in
            self.profile.minimumSharedInterests = value
            return self.profile
        }, setFieldVisibility: { field, level in
            self.profile.fieldVisibility[field] = level
            return self.profile
        })
    }
}
