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
        XCTAssertTrue(driver.discoveryWrites.isEmpty)
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
        XCTAssertFalse(model.profile.prerequisites.link)
        XCTAssertFalse(model.canEnableDiscovery)
        driver.failure = nil
        model.receive(profile: driver.profile)
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
    @MainActor
    func testEachHalfOfActivationGateAlonePreventsTheWrite() async {
        for missingPrerequisites in [true, false] {
            let driver = OnboardingTestDriver()
            driver.profile.prerequisites = .init(displayName: true, introduction: true, interest: true,
                                                  link: !missingPrerequisites)
            let model = driver.model(bluetooth: missingPrerequisites ? .available : .denied)
            XCTAssertFalse(model.canEnableDiscovery)
            await model.finish(discovery: true)
            XCTAssertTrue(driver.discoveryWrites.isEmpty)
            XCTAssertTrue(driver.finishes.isEmpty)
        }
    }

    @MainActor
    func testNamedServerPrerequisitesBecomeUnmetAndRouteToEditors() async {
        for (field, prerequisite, destination) in [
            ("display_name", DiscoveryPrerequisite.displayName, OnboardingStep.basics),
            ("introduction", .introduction, .basics), ("interest", .interest, .interests),
            ("interests", .interest, .interests), ("interest_ids", .interest, .interests),
            ("link", .link, .permissions)
        ] {
            let driver = OnboardingTestDriver()
            driver.profile.displayName = "Name"; driver.profile.introduction = "Intro"
            driver.profile.interestIDs = ["caller"]; driver.profile.purposes = [.discovery]
            driver.profile.prerequisites = .init(displayName: true, introduction: true, interest: true, link: true)
            driver.failure = ProfileActionError(code: .prerequisiteMissing, fields: [field])
            let model = driver.model(bluetooth: .available, hasLinkRoute: true)
            await model.finish(discovery: true)
            XCTAssertEqual(model.profile.prerequisites.missing, [prerequisite])
            XCTAssertFalse(model.canEnableDiscovery)
            if prerequisite == .link { XCTAssertTrue(model.canAddLink) }
            model.edit(prerequisite)
            XCTAssertEqual(driver.linkRoutes, prerequisite == .link ? 1 : 0)
            XCTAssertEqual(model.step, destination)
            XCTAssertNil(model.actionError)
        }
    }

    @MainActor
    func testAccountAndBluetoothFailuresUseTheirOwnMessagesAndModelRetry() async {
        let driver = OnboardingTestDriver()
        driver.profile.prerequisites = .init(displayName: true, introduction: true, interest: true, link: true)
        let model = driver.model(bluetooth: .available)
        driver.failure = ProfileActionError(code: .accountNotReady)
        await model.finish(discovery: true)
        XCTAssertEqual(OnboardingStrings.error(model.actionError!), OnboardingStrings.text(.accountError))
        driver.failure = ProfileActionError(code: .unavailable)
        await model.requestBluetooth()
        XCTAssertEqual(model.failedOperation, .bluetooth)
        XCTAssertEqual(model.errorFallback, .bluetoothUnavailable)
        driver.failure = nil
        await model.retry()
        XCTAssertNil(model.actionError)
        XCTAssertNil(model.failedOperation)
        XCTAssertTrue(driver.finishes.isEmpty)
    }

    @MainActor
    func testFinishAndExitLatchEvenAfterTheirCallbacksReturn() async {
        let driver = OnboardingTestDriver()
        let model = driver.model()
        await model.finish(discovery: false)
        await model.finish(discovery: false)
        model.back()
        XCTAssertTrue(model.hasCompleted)
        XCTAssertEqual(driver.finishes, [false])
        XCTAssertEqual(driver.exits, 0)
        XCTAssertTrue(driver.discoveryWrites.isEmpty)
        let exitDriver = OnboardingTestDriver()
        let exiting = exitDriver.model()
        exiting.back(); exiting.back()
        await exiting.finish(discovery: false)
        XCTAssertEqual(exitDriver.exits, 1)
        XCTAssertTrue(exitDriver.finishes.isEmpty)
    }

    @MainActor
    func testNotNowDisablesDiscoveryOnlyWhenItWasOn() async {
        let driver = OnboardingTestDriver()
        driver.profile.discoveryOn = true
        let model = driver.model()
        driver.failure = ProfileActionError(code: .unavailable)
        await model.finish(discovery: false)
        XCTAssertFalse(model.hasCompleted)
        XCTAssertTrue(model.profile.discoveryOn)
        driver.failure = nil
        await model.retry()
        await model.finish(discovery: false)
        XCTAssertEqual(driver.discoveryWrites, [false, false])
        XCTAssertEqual(driver.finishes, [false])
    }

    @MainActor
    func testSuccessfulWritesApplyWhenTheCallingTaskWasCancelled() async {
        let driver = OnboardingTestDriver()
        driver.cancelSuccessfulWrites = true
        let model = driver.model(interests: driver.options, bluetooth: .available)
        model.displayName = "Name"; model.introduction = "Intro"
        await Task { await model.saveBasics() }.value
        XCTAssertEqual(model.profile.displayName, "Name")
        XCTAssertEqual(model.step, .interests)
        model.selectedInterestIDs = ["caller"]; model.selectedPurposes = [.discovery]
        await Task { await model.saveSelections() }.value
        XCTAssertEqual(model.profile.interestIDs, ["caller"])
        XCTAssertEqual(model.step, .permissions)
        driver.profile.prerequisites.link = true
        model.receive(profile: driver.profile)
        await Task { await model.finish(discovery: true) }.value
        XCTAssertTrue(model.profile.discoveryOn)
        XCTAssertEqual(driver.finishes, [true])
        XCTAssertNil(model.actionError)
    }

    @MainActor
    func testInterestRetryAfterCancellationAndPruningWhenListArrives() async {
        let driver = OnboardingTestDriver()
        let model = driver.model()
        XCTAssertTrue(model.shouldRetryInterestLoad)
        driver.failure = CancellationError()
        await model.loadInterests()
        XCTAssertTrue(model.shouldRetryInterestLoad)
        XCTAssertNil(model.interestLoadError)
        driver.failure = nil
        model.selectedInterestIDs = ["caller", "removed"]
        await model.loadInterests()
        XCTAssertEqual(model.selectedInterestIDs, ["caller"])
        XCTAssertFalse(model.shouldRetryInterestLoad)
        driver.options = []
        await model.loadInterests()
        XCTAssertTrue(model.selectedInterestIDs.isEmpty)
        XCTAssertTrue(model.shouldRetryInterestLoad)
        driver.profile.interestIDs = ["removed"]
        let supplied = driver.model(interests: [])
        XCTAssertTrue(supplied.selectedInterestIDs.isEmpty)
    }

    @MainActor
    func testInterestWriteIsConfirmedEvenWhenTheFollowingPurposeWriteFails() async {
        let driver = OnboardingTestDriver()
        let model = driver.model(interests: driver.options)
        model.selectedInterestIDs = ["caller"]; model.selectedPurposes = [.collaboration]
        driver.failure = ProfileActionError(code: .unavailable)
        driver.failingOperation = "purposes"
        await model.saveSelections()
        XCTAssertEqual(model.profile.interestIDs, ["caller"])
        XCTAssertTrue(model.profile.purposes.isEmpty)
        XCTAssertEqual(model.selectedPurposes, [.collaboration])
        XCTAssertNotNil(model.actionError)
        driver.failure = nil
        await model.retry()
        XCTAssertEqual(driver.interestWrites, 1)
        XCTAssertEqual(driver.purposeWrites, 2)
        XCTAssertEqual(model.step, .permissions)
    }

    @MainActor
    func testEveryTextAndSelectionEditClearsFieldErrors() async {
        let driver = OnboardingTestDriver()
        let model = driver.model(interests: driver.options)
        model.displayName = "Name"; model.introduction = "Intro"
        for field in ["display_name", "introduction"] {
            driver.failure = ProfileActionError(code: .invalidInput, fields: [field])
            await model.saveBasics()
            XCTAssertNotNil(model.actionError)
            if field == "display_name" { model.displayName += "x" } else { model.introduction += "x" }
            XCTAssertNil(model.actionError)
        }
        model.selectedInterestIDs = ["caller"]; model.selectedPurposes = [.discovery]
        for field in ["interests", "purposes"] {
            driver.failure = ProfileActionError(code: .invalidInput, fields: [field])
            await model.saveSelections()
            XCTAssertNotNil(model.actionError)
            if field == "interests" { model.selectedInterestIDs = [] } else { model.selectedPurposes = [.collaboration] }
            XCTAssertNil(model.actionError)
            model.selectedInterestIDs = ["caller"]
        }
    }

}

@MainActor
private final class OnboardingTestDriver {
    var profile = OwnProfileState()
    var options = [InterestOption(id: "caller", labelJapanese: "選択肢", labelEnglish: "Option")]
    var permission = BluetoothPermissionState.available
    var failure: (any Error)?
    var failingOperation: String?
    var interestWrites = 0
    var purposeWrites = 0
    var savedName: String?
    var basicWrites = 0
    var discoveryWrites: [Bool] = []
    var finishes: [Bool] = []
    var exits = 0
    var recoveries = 0
    var linkRoutes = 0
    var cancelSuccessfulWrites = false
    var duringSave: (@MainActor () async -> Void)?

    func model(interests: [InterestOption]? = nil,
               bluetooth: BluetoothPermissionState = .notRequested, hasLinkRoute: Bool = false) -> OnboardingModel {
        let linkRoute: (@MainActor () -> Void)?
        if hasLinkRoute { linkRoute = { self.linkRoutes += 1 } } else { linkRoute = nil }
        return OnboardingModel(profile: profile, interests: interests, bluetooth: bluetooth, actions: actions,
                        onExit: { self.exits += 1 }, onFinish: { self.finishes.append($0) },
                        onBluetoothRecovery: { self.recoveries += 1 },
                        onAddLink: linkRoute)
    }

    private func checkFailure(_ operation: String) throws {
        if let failure, failingOperation == nil || failingOperation == operation { throw failure }
    }

    private var actions: ProfileActions {
        ProfileActions(loadInterests: {
            try self.checkFailure("load")
            return self.options
        }, saveProfile: { name, introduction, contact in
            self.basicWrites += 1
            await self.duringSave?()
            try self.checkFailure("profile")
            self.savedName = name
            self.profile.displayName = name
            self.profile.introduction = introduction
            self.profile.contactDetail = contact
            self.profile.prerequisites.displayName = !name.isEmpty
            self.profile.prerequisites.introduction = !introduction.isEmpty
            if self.cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
            return self.profile
        }, saveInterests: { interests in
            self.interestWrites += 1
            try self.checkFailure("interests")
            self.profile.interestIDs = interests
            self.profile.prerequisites.interest = !interests.isEmpty
            if self.cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
            return self.profile
        }, savePurposes: { purposes in
            self.purposeWrites += 1
            try self.checkFailure("purposes")
            self.profile.purposes = purposes
            if self.cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
            return self.profile
        }, setDiscovery: { enabled in
            self.discoveryWrites.append(enabled)
            try self.checkFailure("discovery")
            self.profile.discoveryOn = enabled
            if self.cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
            return self.profile
        }, requestBluetooth: {
            try self.checkFailure("bluetooth")
            return self.permission
        }, setMinimumSharedInterests: { value in
            self.profile.minimumSharedInterests = value
            if self.cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
            return self.profile
        }, setFieldVisibility: { field, level in
            self.profile.fieldVisibility[field] = level
            if self.cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
            return self.profile
        })
    }
}
