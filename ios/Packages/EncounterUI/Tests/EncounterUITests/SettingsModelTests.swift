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
        XCTAssertEqual(driver.writes, ["interests", "purposes", "profile", "interests", "purposes"])
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
        model.selectedInterestIDs = ["ios", "web"]
        driver.failAt = "interests"
        driver.failure = ProfileActionError(code: .invalidInput, fields: ["interest_ids"])
        let first = await model.saveProfile()
        XCTAssertFalse(first)
        XCTAssertEqual(model.displayName, " Edited ")
        XCTAssertEqual(model.selectedInterestIDs, ["ios", "web"])
        XCTAssertEqual(model.profile.displayName, "Edited")
        XCTAssertEqual(model.profile.interestIDs, ["ios"])
        XCTAssertEqual(model.errors[.profile]?.fields, ["interest_ids"])
        XCTAssertEqual(model.appliedChanges[.profile], [.field(.displayName)])
        let announcement = SettingsSaveFeedback.announcement(model: model, screen: .profile)
        XCTAssertTrue(announcement?.contains(SettingsStrings.text(.partialSave)) == true)
        XCTAssertTrue(announcement?.contains("Edited") == true)
        XCTAssertEqual(model.failedOperations[.profile], .profile)
        driver.failAt = nil
        let retry = await model.retry(.profile)
        XCTAssertTrue(retry)
        XCTAssertEqual(driver.writes, ["profile", "interests", "interests"])
        XCTAssertNil(model.errors[.profile])
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testInterestLoadingFailureAndEmptyListPreserveDraftAndCanRetry() async {
        let driver = SettingsTestDriver()
        let model = driver.model(interestsLoaded: false)
        model.displayName = "Draft"
        model.selectedInterestIDs = ["ios"]
        driver.failAt = "load"
        await model.loadInterests()
        XCTAssertFalse(model.hasLoadedInterests)
        XCTAssertNotNil(model.interestLoadError)
        XCTAssertEqual(model.displayName, "Draft")
        XCTAssertEqual(model.selectedInterestIDs, ["ios"])
        driver.failAt = nil
        driver.options = []
        await model.loadInterests()
        XCTAssertTrue(model.hasLoadedInterests)
        XCTAssertTrue(model.canSaveProfile)
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
        driver.failAt = "purposes"
        await model.saveMatching()
        XCTAssertEqual(model.profile.purposes, [.discovery])
        XCTAssertEqual(model.profile.minimumSharedInterests, 10)
        XCTAssertEqual(model.minimumSharedInterests, 10)
        XCTAssertEqual(model.selectedPurposes, [.discovery, .collaboration])
        driver.failAt = nil
        await model.saveMatching()
        XCTAssertEqual(driver.writes, ["threshold", "purposes", "purposes", "purposes"])
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
            XCTAssertEqual(SettingsSaveFeedback.announcement(model: model, screen: .profile), SettingsStrings.text(.loading))
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
        let activationModel = driver.model(allowsActivation: true, bluetooth: .notRequested)
        await activationModel.requestBluetooth()
        XCTAssertEqual(activationModel.bluetooth, .denied)
        XCTAssertFalse(activationModel.profile.discoveryOn)
        XCTAssertFalse(activationModel.canEnableDiscovery)
    }
    @MainActor
    func testEmptyDiscoveryPrerequisitesCanBeSavedOnlyWhileDiscoveryIsOff() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        model.displayName = " \n"; model.introduction = ""; model.selectedInterestIDs = []
        XCTAssertTrue(model.canSaveProfile)
        let saved = await model.saveProfile()
        XCTAssertTrue(saved)
        XCTAssertEqual(model.profile.displayName, "")
        XCTAssertEqual(model.profile.introduction, "")
        XCTAssertTrue(model.profile.interestIDs.isEmpty)
        XCTAssertEqual(driver.writes, ["profile", "interests"])
    }

    @MainActor
    func testUnavailableCatalogueDoesNotBlockSavingOtherFields() async {
        for discoveryOn in [false, true] {
            for emptyList in [false, true] {
                let driver = SettingsTestDriver()
                driver.profile.discoveryOn = discoveryOn
                driver.options = []
                let model = driver.model(interestsLoaded: emptyList)
                if !emptyList {
                    driver.failAt = "load"
                    await model.loadInterests()
                    XCTAssertNotNil(model.interestLoadError)
                }
                driver.failAt = nil
                model.contactDetail = "Updated contact"
                XCTAssertTrue(model.canSaveProfile)
                let saved = await model.saveProfile()
                XCTAssertTrue(saved)
                XCTAssertEqual(model.profile.contactDetail, "Updated contact")
                XCTAssertEqual(model.profile.interestIDs, ["ios"])
                XCTAssertFalse(driver.writes.contains("interests"))
                XCTAssertFalse(driver.writes.contains("purposes"))
            }
        }
    }

    @MainActor
    func testMembershipWaitsForLoadedListAndDoesNotDiscardSettingsDraft() async {
        let driver = SettingsTestDriver()
        let model = driver.model(interestsLoaded: false)
        model.selectedInterestIDs = ["unlisted"]
        XCTAssertFalse(model.invalidProfileFields.contains(.interests))
        await model.loadInterests()
        XCTAssertEqual(model.selectedInterestIDs, ["unlisted"])
        XCTAssertTrue(model.invalidProfileFields.contains(.interests))
        XCTAssertFalse(model.canSaveProfile)
    }

    @MainActor
    func testProfilePurposesRefreshMatchingEvenWithDirtyThreshold() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        model.minimumSharedInterests = 7
        model.selectedPurposes = [.collaboration]
        let saved = await model.saveProfile()
        XCTAssertTrue(saved)
        XCTAssertEqual(model.matchingPurposes, [.collaboration])
        XCTAssertEqual(model.minimumSharedInterests, 7)
        XCTAssertEqual(model.profile.minimumSharedInterests, 1)
        let otherDriver = SettingsTestDriver()
        let dirtyPurposes = otherDriver.model()
        dirtyPurposes.matchingPurposes = []
        dirtyPurposes.selectedPurposes = [.collaboration]
        let otherSaved = await dirtyPurposes.saveProfile()
        XCTAssertTrue(otherSaved)
        XCTAssertTrue(dirtyPurposes.matchingPurposes.isEmpty)
    }

    @MainActor
    func testFreshCallerStateUpdatesCleanDraftsAndPreservesEveryDirtyDraft() {
        let driver = SettingsTestDriver()
        let model = driver.model()
        model.displayName = "Draft name"
        model.selectedInterestIDs = ["web"]
        model.matchingPurposes = [.collaboration]
        model.minimumSharedInterests = 8
        model.visibility[.displayName] = .private
        var fresh = driver.profile
        fresh.displayName = "Server name"; fresh.introduction = "Fresh intro"; fresh.contactDetail = "Fresh contact"
        fresh.interestIDs = ["backend"]; fresh.purposes = [.discovery, .collaboration]
        fresh.minimumSharedInterests = 2; fresh.fieldVisibility[.introduction] = .compatibleOnly
        fresh.prerequisites.link = true
        model.receive(profile: fresh, bluetooth: .poweredOff)
        XCTAssertEqual(model.profile, fresh)
        XCTAssertEqual(model.displayName, "Draft name")
        XCTAssertEqual(model.introduction, "Fresh intro")
        XCTAssertEqual(model.contactDetail, "Fresh contact")
        XCTAssertEqual(model.selectedInterestIDs, ["web"])
        XCTAssertEqual(model.selectedPurposes, fresh.purposes)
        XCTAssertEqual(model.matchingPurposes, [.collaboration])
        XCTAssertEqual(model.minimumSharedInterests, 8)
        XCTAssertEqual(model.visibility[.displayName], .private)
        XCTAssertEqual(model.visibility[.introduction], .compatibleOnly)
        XCTAssertEqual(model.bluetooth, .poweredOff)
        model.receive(bluetooth: .available)
        XCTAssertEqual(model.bluetooth, .available)
    }

    @MainActor
    func testProfileRemovalsPrecedeAdditionsAcrossAllWrites() async {
        let driver = SettingsTestDriver()
        driver.profile.contactDetail = "Remove me"
        driver.profile.interestIDs = ["ios", "backend"]
        driver.profile.purposes = [.discovery, .collaboration]
        let model = driver.model()
        model.displayName = "New name"; model.contactDetail = ""
        model.selectedInterestIDs = ["ios", "web"]; model.selectedPurposes = [.collaboration]
        let saved = await model.saveProfile()
        XCTAssertTrue(saved)
        XCTAssertEqual(driver.writes, ["profile", "interests", "purposes", "profile", "interests"])
        XCTAssertEqual(driver.confirmed[0].contactDetail, "")
        XCTAssertEqual(driver.confirmed[0].displayName, "Name")
        XCTAssertEqual(driver.confirmed[1].interestIDs, ["ios"])
        XCTAssertEqual(driver.confirmed[2].purposes, [.collaboration])
        XCTAssertEqual(driver.confirmed[3].displayName, "New name")
        XCTAssertEqual(driver.confirmed[4].interestIDs, ["ios", "web"])
    }

    @MainActor
    func testDisjointInterestReplacementWhileOnNarrowsPurposesFirst() async {
        let driver = SettingsTestDriver()
        driver.profile.discoveryOn = true
        let model = driver.model()
        model.selectedInterestIDs = ["web"]
        let saved = await model.saveProfile()
        XCTAssertTrue(saved)
        XCTAssertEqual(driver.writes, ["purposes", "interests", "purposes"])
        XCTAssertEqual(driver.confirmed[0].interestIDs, ["ios"])
        XCTAssertTrue(driver.confirmed[0].purposes.isEmpty)
        XCTAssertEqual(driver.confirmed[1].interestIDs, ["web"])
        XCTAssertTrue(driver.confirmed[1].purposes.isEmpty)
        XCTAssertEqual(driver.confirmed[2].purposes, [.discovery])
        XCTAssertTrue(driver.confirmed.allSatisfy { !$0.interestIDs.isEmpty && $0.discoveryOn })
    }

    @MainActor
    func testDisjointInterestFailurePreservesUnchangedPurposeDraftForRetry() async {
        let driver = SettingsTestDriver()
        driver.profile.discoveryOn = true
        let model = driver.model()
        model.selectedInterestIDs = ["web"]
        driver.failAt = "interests"
        let first = await model.saveProfile()
        XCTAssertFalse(first)
        XCTAssertTrue(model.profile.purposes.isEmpty)
        XCTAssertEqual(model.selectedPurposes, [.discovery])
        XCTAssertEqual(model.selectedInterestIDs, ["web"])
        XCTAssertTrue(model.canRetry(.profile))
        XCTAssertEqual(model.appliedChanges[.profile], [.field(.purposes)])
        driver.failAt = nil
        let saved = await model.retry(.profile)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.profile.interestIDs, ["web"])
        XCTAssertEqual(model.profile.purposes, [.discovery])
        XCTAssertEqual(driver.writes, ["purposes", "interests", "interests", "purposes"])
    }

    @MainActor
    func testMatchingNarrowingBeforeWideningAndPartialReceipt() async {
        let driver = SettingsTestDriver()
        driver.profile.minimumSharedInterests = 4
        driver.profile.purposes = [.discovery, .collaboration]
        let model = driver.model()
        model.matchingPurposes = [.collaboration]
        model.minimumSharedInterests = 2
        driver.failAt = "threshold"
        await model.saveMatching()
        XCTAssertEqual(driver.writes, ["purposes", "threshold"])
        XCTAssertEqual(model.profile.purposes, [.collaboration])
        XCTAssertEqual(model.profile.minimumSharedInterests, 4)
        XCTAssertEqual(model.appliedChanges[.discovery], [.field(.purposes)])
        XCTAssertEqual(model.failedOperations[.discovery], .matching)
        driver.failAt = nil
        let saved = await model.retry(.discovery)
        XCTAssertTrue(saved)
        XCTAssertEqual(driver.writes, ["purposes", "threshold", "threshold"])
        XCTAssertNil(model.appliedChanges[.discovery])
    }

    @MainActor
    func testThresholdIncreasePrecedesPurposeWidening() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        model.matchingPurposes = [.discovery, .collaboration]; model.minimumSharedInterests = 5
        await model.saveMatching()
        XCTAssertEqual(driver.writes, ["threshold", "purposes"])
        XCTAssertEqual(driver.confirmed[0].purposes, [.discovery])
        XCTAssertEqual(driver.confirmed[0].minimumSharedInterests, 5)
    }

    @MainActor
    func testVisibilityNarrowsBeforeEarlierFieldWidensAndReceiptSurvivesRetryFailure() async {
        let driver = SettingsTestDriver()
        driver.profile.fieldVisibility[.displayName] = .private
        let model = driver.model()
        model.visibility[.displayName] = .everyoneEligible
        model.visibility[.introduction] = .private
        driver.failAt = "visibility:display_name"
        await model.saveVisibility()
        XCTAssertEqual(driver.writes, ["visibility:introduction", "visibility:display_name"])
        XCTAssertEqual(model.appliedChanges[.visibility], [.field(.introduction)])
        let messages = SettingsAppliedChanges.messages(model: model, screen: .visibility, language: "en")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains(SettingsStrings.text(.introduction)))
        XCTAssertTrue(messages[0].contains(SettingsStrings.text(.privateLevel)))
        await model.retry(.visibility)
        XCTAssertEqual(model.appliedChanges[.visibility], [.field(.introduction)])
        driver.failAt = nil
        await model.retry(.visibility)
        XCTAssertEqual(model.profile.fieldVisibility[.displayName], .everyoneEligible)
        XCTAssertNil(model.errors[.visibility])
    }

    @MainActor
    func testLoadingAllowsTextChangesAndDiscardAndSkippedLoadResumesAfterSave() async {
        let driver = SettingsTestDriver()
        let model = driver.model(interestsLoaded: false)
        driver.duringLoad = {
            XCTAssertTrue(model.isLoadingInterests)
            XCTAssertFalse(model.isSaving)
            model.displayName = "Loading draft"
            XCTAssertEqual(model.displayName, "Loading draft")
            model.discard(.profile)
            XCTAssertEqual(model.displayName, "Name")
            model.introduction = "Editable intro"
            XCTAssertTrue(model.canSaveProfile)
        }
        await model.loadInterests()
        XCTAssertEqual(model.introduction, "Editable intro")
        let (loads, loadCompletion) = AsyncStream<Void>.makeStream()
        driver.duringLoad = { loadCompletion.yield(()); loadCompletion.finish() }
        driver.duringProfileSave = {
            await model.loadInterests()
            XCTAssertFalse(model.isLoadingInterests)
        }
        let saved = await model.saveProfile()
        XCTAssertTrue(saved)
        // The stream is registered before saving, so the completion cannot race the observer.
        for await _ in loads { break }
        XCTAssertEqual(driver.writes, ["load", "profile", "load"])
    }

    @MainActor
    func testFailedOperationSurvivesViewRecreationAndBluetoothIsUnavailableUntilActivation() async {
        let driver = SettingsTestDriver()
        let unavailable = driver.model(bluetooth: .notRequested)
        XCTAssertFalse(unavailable.canRequestBluetooth)
        await unavailable.requestBluetooth()
        XCTAssertTrue(driver.writes.isEmpty)
        driver.profile.discoveryOn = true
        let model = driver.model(allowsActivation: true, bluetooth: .notRequested)
        driver.failAt = "discovery"
        await model.setDiscovery(false)
        XCTAssertEqual(model.failedOperations[.discovery], .discovery(false))
        driver.failAt = nil
        await model.retry(.discovery)
        XCTAssertFalse(model.profile.discoveryOn)
        driver.failAt = "bluetooth"
        await model.requestBluetooth()
        XCTAssertEqual(model.failedOperations[.discovery], .bluetooth)
        XCTAssertEqual(model.errorFallback(.discovery), .bluetoothUnavailable)
        driver.failAt = nil
        await model.retry(.discovery)
        XCTAssertEqual(model.bluetooth, .available)
        XCTAssertEqual(driver.writes, ["discovery", "discovery", "bluetooth", "bluetooth"])
    }

    @MainActor
    func testErrorsClearOnEveryDraftEditAndWhenLeavingEachScreen() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        let profileEdits: [@MainActor () -> Void] = [
            { model.displayName += "x" }, { model.introduction += "x" }, { model.contactDetail += "x" },
            { model.selectedInterestIDs = ["ios", "web"] }, { model.selectedPurposes = [.discovery, .collaboration] }
        ]
        for edit in profileEdits {
            driver.failAt = "profile"
            model.displayName += "x"
            _ = await model.saveProfile()
            XCTAssertNotNil(model.errors[.profile])
            edit()
            XCTAssertNil(model.errors[.profile])
        }
        driver.failAt = "threshold"
        model.minimumSharedInterests = 7
        await model.saveMatching()
        XCTAssertNotNil(model.errors[.discovery])
        model.minimumSharedInterests = 8
        XCTAssertNil(model.errors[.discovery])
        await model.saveMatching()
        model.matchingPurposes = [.collaboration]
        XCTAssertNil(model.errors[.discovery])
        driver.failAt = "visibility:display_name"
        model.visibility[.displayName] = .private
        await model.saveVisibility()
        XCTAssertNotNil(model.errors[.visibility])
        model.visibility[.displayName] = .compatibleOnly
        XCTAssertNil(model.errors[.visibility])
        await model.saveVisibility()
        XCTAssertNotNil(model.errors[.visibility])
        for screen in [SettingsScreen.profile, .discovery, .visibility] {
            let operation = model.failedOperations[screen]
            model.leave(screen)
            XCTAssertEqual(model.failedOperations[screen], operation)
            XCTAssertNil(model.errors[screen])
            XCTAssertNil(SettingsSaveFeedback.announcement(model: model, screen: screen))
        }
    }

    @MainActor
    func testPurposeFailureAfterInterestSuccessShowsReceiptAndRetrySkipsInterests() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        model.selectedInterestIDs = ["ios", "web"]
        model.selectedPurposes = [.discovery, .collaboration]
        driver.failAt = "purposes"
        let first = await model.saveProfile()
        XCTAssertFalse(first)
        XCTAssertEqual(model.profile.interestIDs, ["ios", "web"])
        XCTAssertEqual(model.profile.purposes, [.discovery])
        XCTAssertEqual(model.appliedChanges[.profile], [.field(.interests)])
        XCTAssertEqual(model.selectedPurposes, [.discovery, .collaboration])
        let messages = SettingsAppliedChanges.messages(model: model, screen: .profile, language: "en")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("Web"))
        driver.failAt = nil
        let retry = await model.retry(.profile)
        XCTAssertTrue(retry)
        XCTAssertEqual(driver.writes, ["interests", "purposes", "purposes"])
    }

    @MainActor
    func testSettingsAppliesSuccessfulWritesFromCancelledCallingTask() async {
        let driver = SettingsTestDriver()
        let model = driver.model()
        driver.cancelSuccessfulWrites = true
        model.displayName = "Confirmed after cancellation"
        let saved = await Task { await model.saveProfile() }.value
        XCTAssertTrue(saved)
        XCTAssertEqual(model.profile.displayName, "Confirmed after cancellation")
        model.minimumSharedInterests = 6
        await Task { await model.saveMatching() }.value
        XCTAssertEqual(model.profile.minimumSharedInterests, 6)
        model.visibility[.contactDetail] = .compatibleOnly
        await Task { await model.saveVisibility() }.value
        XCTAssertEqual(model.profile.fieldVisibility[.contactDetail], .compatibleOnly)
        driver.profile.discoveryOn = true
        model.receive(profile: driver.profile)
        let disabled = await Task { await model.setDiscovery(false) }.value
        XCTAssertTrue(disabled)
        XCTAssertFalse(model.profile.discoveryOn)
    }

}

@MainActor
private final class SettingsTestDriver {
    var profile = OwnProfileState(displayName: "Name", introduction: "Introduction", interestIDs: ["ios"], purposes: [.discovery],
                                  prerequisites: .init(displayName: true, introduction: true, interest: true))
    var options = InterimProfileInterests.options
    var writes: [String] = []
    var confirmed: [OwnProfileState] = []
    var cancelSuccessfulWrites = false
    var duringLoad: (@MainActor () async -> Void)?
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
            await self.duringLoad?()
            try self.attempt("load")
            return self.options
        }, saveProfile: { name, intro, contact in
            await self.duringProfileSave?()
            try self.attempt("profile")
            self.profile.displayName = name; self.profile.introduction = intro; self.profile.contactDetail = contact
            self.profile.prerequisites.displayName = !name.isEmpty
            self.profile.prerequisites.introduction = !intro.isEmpty
            self.confirmed.append(self.profile)
            if self.cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
            return self.profile
        }, saveInterests: { interests in
            try self.attempt("interests")
            self.profile.interestIDs = interests
            self.profile.prerequisites.interest = !interests.isEmpty
            self.confirmed.append(self.profile)
            if self.cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
            return self.profile
        }, savePurposes: { purposes in
            try self.attempt("purposes")
            self.profile.purposes = purposes
            self.confirmed.append(self.profile)
            if self.cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
            return self.profile
        }, setDiscovery: { enabled in
            try self.attempt("discovery")
            self.profile.discoveryOn = enabled
            self.confirmed.append(self.profile)
            if self.cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
            return self.profile
        }, requestBluetooth: {
            try self.attempt("bluetooth")
            return self.permission
        }, setMinimumSharedInterests: { value in
            try self.attempt("threshold")
            self.profile.minimumSharedInterests = value
            self.confirmed.append(self.profile)
            if self.cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
            return self.profile
        }, setFieldVisibility: { field, level in
            try self.attempt("visibility:" + field.rawValue)
            self.profile.fieldVisibility[field] = level
            self.confirmed.append(self.profile)
            if self.cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
            return self.profile
        })
    }
}
