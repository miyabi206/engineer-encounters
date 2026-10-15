import XCTest
@testable import EncounterUI

final class AccountSettingsTests: XCTestCase {
    func testDeletionStateRequiresAcknowledgementAndLocksPendingAndTerminalStates() {
        var state = AccountSettingsDeletionState.idle
        XCTAssertFalse(state.preventsSignedInDismissal)
        state.accept(deleted: true)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(state.begin())
        XCTAssertTrue(state.preventsSignedInDismissal)
        XCTAssertFalse(state.cancel())
        XCTAssertFalse(state.begin())
        state.accept(deleted: false)
        XCTAssertEqual(state, .failed)
        XCTAssertTrue(state.canRetry)
        XCTAssertFalse(state.preventsSignedInDismissal)
        XCTAssertTrue(state.begin())
        state.fail(.init(code: .prerequisiteMissing, fields: ["deletion_safety_key"]))
        XCTAssertEqual(state, .configurationRequired)
        XCTAssertTrue(state.canRetry)
        XCTAssertFalse(state.preventsSignedInDismissal)
        XCTAssertTrue(state.begin())
        state.accept(deleted: true)
        XCTAssertEqual(state, .deleted)
        XCTAssertTrue(state.preventsSignedInDismissal)
        XCTAssertFalse(state.begin())
        XCTAssertFalse(state.cancel())
    }

    func testDeletionAuthExpiryAndOrdinaryPrerequisiteFailure() {
        var state = AccountSettingsDeletionState.idle
        XCTAssertTrue(state.begin())
        state.fail(.init(code: .prerequisiteMissing, fields: ["other"]))
        XCTAssertEqual(state, .failed)
        XCTAssertTrue(state.begin())
        state.fail(.init(code: .notAuthenticated))
        XCTAssertEqual(state, .authenticationExpired)
        XCTAssertTrue(state.preventsSignedInDismissal)
        XCTAssertFalse(state.canRetry)
    }

    func testLastLinkRefusalOnlyWhileDiscoveryIsOnAndRepositoriesAreRemoved() {
        for discoveryOn in [false, true] {
            for linkCount in [0, 1, 2] {
                for repositoryCount in [0, 1, 2] {
                    let data = AccountSettingsData(discoveryOn: discoveryOn, linkCount: linkCount,
                                                   githubRepositoryCount: repositoryCount)
                    XCTAssertEqual(data.disconnectRemovesLastLink,
                                   discoveryOn && repositoryCount > 0 && linkCount <= repositoryCount)
                }
            }
        }
    }

    @MainActor
    func testDeletionSuspendsBeforeIOAndBlocksDuplicateActionsAndBack() async {
        let driver = AccountSettingsTestDriver()
        let model = driver.model()
        driver.duringDeletion = {
            XCTAssertEqual(model.deletion, .pending)
            XCTAssertFalse(model.canDismiss)
            XCTAssertEqual(driver.calls, ["suspend", "delete"])
            await model.back()
            await model.load()
            await model.signOut()
            await model.disconnect()
            await model.deleteAccount()
            await model.cancelDeletion()
        }
        await model.deleteAccount()
        XCTAssertEqual(model.deletion, .deleted)
        XCTAssertFalse(model.canDismiss)
        await model.back()
        await model.cancelDeletion()
        XCTAssertNil(model.data)
        XCTAssertEqual(driver.calls, ["suspend", "delete", "signedOut"])
        XCTAssertNil(model.error)
    }

    @MainActor
    func testDeletionFailuresAllowDismissalAndRetryCanComplete() async {
        for configurationRequired in [false, true] {
            let driver = AccountSettingsTestDriver()
            let model = driver.model()
            driver.failure = configurationRequired ?
                ProfileActionError(code: .prerequisiteMissing, fields: ["deletion_safety_key"]) :
                ProfileActionError(code: .unavailable)
            await model.deleteAccount()
            XCTAssertEqual(model.deletion, configurationRequired ? .configurationRequired : .failed)
            XCTAssertEqual(model.failedOperation, .delete)
            XCTAssertNotNil(model.data)
            XCTAssertTrue(model.canDismiss)
            XCTAssertTrue(model.deletion.canRetry)
            await model.load()
            XCTAssertEqual(model.failedOperation, .delete)
            XCTAssertEqual(driver.calls, ["suspend", "delete"])
            driver.failure = nil
            await model.retry()
            XCTAssertEqual(model.deletion, .deleted)
            XCTAssertEqual(driver.calls, ["suspend", "delete", "suspend", "delete", "signedOut"])
        }
    }

    @MainActor
    func testCancelDeletionFailuresResumesParticipationAndClearsFailureOnce() async {
        for configurationRequired in [false, true] {
            let driver = AccountSettingsTestDriver()
            let model = driver.model()
            driver.failure = configurationRequired ?
                ProfileActionError(code: .prerequisiteMissing, fields: ["deletion_safety_key"]) :
                ProfileActionError(code: .unavailable)
            await model.deleteAccount()
            await model.cancelDeletion()
            await model.cancelDeletion()
            await model.retry()
            XCTAssertEqual(model.deletion, .idle)
            XCTAssertTrue(model.canDismiss)
            XCTAssertNotNil(model.data)
            XCTAssertNil(model.error)
            XCTAssertNil(model.failedOperation)
            XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount", "resume"])
            await model.back()
            XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount", "resume", "back"])
        }
    }

    @MainActor
    func testBackAndSignOutAfterDeletionFailureCancelSuspension() async {
        for configurationRequired in [false, true] {
            for signOut in [false, true] {
                let driver = AccountSettingsTestDriver()
                let model = driver.model()
                driver.failure = configurationRequired ?
                    ProfileActionError(code: .prerequisiteMissing, fields: ["deletion_safety_key"]) :
                    ProfileActionError(code: .unavailable)
                await model.deleteAccount()
                driver.failure = nil
                if signOut { await model.signOut() } else { await model.back() }
                XCTAssertEqual(model.deletion, .idle)
                XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount", "resume"] +
                               (signOut ? ["signOut", "signedOut"] : ["back"]))
            }
        }
    }

    @MainActor
    func testOfflineAndFalseDeletionNeverNavigateOrClaimSuccess() async {
        for failure in [false, true] {
            let driver = AccountSettingsTestDriver()
            driver.deleted = false
            if failure { driver.failure = ProfileActionError(code: .unavailable) }
            let model = driver.model()
            await model.deleteAccount()
            XCTAssertEqual(model.deletion, .failed)
            XCTAssertTrue(model.canDismiss)
            XCTAssertEqual(driver.calls, ["suspend", "delete"])
            XCTAssertNotNil(model.error)
        }
    }

    @MainActor
    func testDeletionAuthExpiryReturnsToSignInWithoutDeletionReceipt() async {
        let driver = AccountSettingsTestDriver()
        driver.failure = ProfileActionError(code: .notAuthenticated)
        let model = driver.model()
        await model.deleteAccount()
        XCTAssertEqual(model.deletion, .authenticationExpired)
        XCTAssertFalse(model.canDismiss)
        await model.back()
        await model.cancelDeletion()
        XCTAssertNil(model.data)
        XCTAssertEqual(driver.calls, ["suspend", "delete", "signedOut"])
    }

    @MainActor
    func testCancelLocksUntilFreshAccountIsConfirmedAndResumesOnlyOnce() async {
        let driver = AccountSettingsTestDriver()
        driver.failure = ProfileActionError(code: .unavailable)
        let model = driver.model()
        await model.deleteAccount()
        driver.data.discoveryOn = true
        driver.data.githubConnected = false
        driver.duringReload = {
            XCTAssertTrue(model.isBusy)
            XCTAssertFalse(model.canDismiss)
            XCTAssertEqual(model.deletion, .failed)
            XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount"])
            await model.back()
            await model.cancelDeletion()
            await model.deleteAccount()
            await model.signOut()
            await model.disconnect()
            await model.retry()
        }
        await model.cancelDeletion()
        XCTAssertEqual(model.data, driver.data)
        XCTAssertEqual(model.deletion, .idle)
        XCTAssertTrue(model.canDismiss)
        XCTAssertNil(model.error)
        XCTAssertNil(model.failedOperation)
        XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount", "resume"])
    }

    @MainActor
    func testCancelWithGoneOrUnauthenticatedAccountLocksAndNeverResumes() async {
        for state in [AccountSettingsAccountState.deleted, .authenticationExpired] {
            let driver = AccountSettingsTestDriver()
            driver.failure = ProfileActionError(code: .unavailable)
            driver.accountState = state
            let model = driver.model()
            await model.deleteAccount()
            await model.cancelDeletion()
            XCTAssertEqual(model.deletion, state == .deleted ? .deleted : .authenticationExpired)
            XCTAssertNil(model.data)
            XCTAssertFalse(model.canDismiss)
            XCTAssertNil(model.error)
            await model.back()
            await model.cancelDeletion()
            await model.retry()
            await model.load()
            await model.signOut()
            await model.disconnect()
            await model.deleteAccount()
            XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount", "signedOut"])
        }
    }

    @MainActor
    func testBackSignOutAndDisconnectCannotProceedIfCancellationFindsAccountGone() async {
        for operation in [AccountSettingsOperation.load, .signOut, .disconnect] {
            let driver = AccountSettingsTestDriver()
            driver.failure = ProfileActionError(code: .unavailable)
            driver.accountState = .deleted
            let model = driver.model()
            await model.deleteAccount()
            switch operation {
            case .signOut: await model.signOut()
            case .disconnect: await model.disconnect()
            default: await model.back()
            }
            XCTAssertEqual(model.deletion, .deleted)
            XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount", "signedOut"])
        }
    }

    @MainActor
    func testCancelVerificationFailureStaysSuspendedAndRetryRechecksAccount() async {
        let driver = AccountSettingsTestDriver()
        driver.failure = ProfileActionError(code: .unavailable)
        driver.reloadFailure = ProfileActionError(code: .unavailable)
        let model = driver.model()
        await model.deleteAccount()
        await model.cancelDeletion()
        XCTAssertEqual(model.deletion, .failed)
        XCTAssertEqual(model.failedOperation, .checkAccount)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount"])
        driver.reloadFailure = nil
        await model.retry()
        XCTAssertEqual(model.deletion, .idle)
        XCTAssertNil(model.error)
        XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount", "reloadAccount", "resume"])
    }

    @MainActor
    func testCancelVerificationAuthErrorLocksAndRoutesWithoutResuming() async {
        let driver = AccountSettingsTestDriver()
        driver.failure = ProfileActionError(code: .unavailable)
        driver.reloadFailure = ProfileActionError(code: .notAuthenticated)
        let model = driver.model()
        await model.deleteAccount()
        await model.cancelDeletion()
        XCTAssertEqual(model.deletion, .authenticationExpired)
        XCTAssertNil(model.data)
        XCTAssertFalse(model.canDismiss)
        XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount", "signedOut"])
    }

    @MainActor
    func testDeletionFailureAfterDisappearanceVerifiesBeforeResumingOrRouting() async {
        for configurationRequired in [false, true] {
            for accountState in [AccountSettingsAccountState.present(.init()), .deleted, .authenticationExpired] {
                let driver = AccountSettingsTestDriver()
                driver.failure = configurationRequired ?
                    ProfileActionError(code: .prerequisiteMissing, fields: ["deletion_safety_key"]) :
                    ProfileActionError(code: .unavailable)
                driver.accountState = accountState
                let model = driver.model()
                driver.duringDeletion = {
                    model.disappear()
                    XCTAssertFalse(model.canDismiss)
                }
                await model.deleteAccount()
                if case .present(let fresh) = accountState {
                    XCTAssertEqual(model.deletion, .idle)
                    XCTAssertEqual(model.data, fresh)
                    XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount", "resume"])
                } else {
                    XCTAssertEqual(model.deletion, accountState == .deleted ? .deleted : .authenticationExpired)
                    XCTAssertNil(model.data)
                    XCTAssertFalse(model.canDismiss)
                    XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount", "signedOut"])
                }
                XCTAssertFalse(model.isBusy)
            }
        }
    }

    @MainActor
    func testOffscreenVerificationFailureRoutesToSignInWithoutResuming() async {
        let driver = AccountSettingsTestDriver()
        driver.failure = ProfileActionError(code: .unavailable)
        driver.reloadFailure = ProfileActionError(code: .unavailable)
        let model = driver.model()
        driver.duringDeletion = { model.disappear() }
        await model.deleteAccount()
        XCTAssertEqual(model.deletion, .failed)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.data)
        XCTAssertEqual(driver.calls, ["suspend", "delete", "reloadAccount", "signedOut"])
    }

    @MainActor
    func testOffscreenDeletionCompletionAndAuthExpiryRouteWithoutResuming() async {
        for authExpired in [false, true] {
            let driver = AccountSettingsTestDriver()
            if authExpired { driver.failure = ProfileActionError(code: .notAuthenticated) }
            let model = driver.model()
            driver.duringDeletion = { model.disappear() }
            await model.deleteAccount()
            XCTAssertEqual(model.deletion, authExpired ? .authenticationExpired : .deleted)
            XCTAssertFalse(model.canDismiss)
            XCTAssertEqual(driver.calls, ["suspend", "delete", "signedOut"])
        }
    }

    @MainActor
    func testSupportIsShownOnlyWhenAnActionIsSupplied() {
        let driver = AccountSettingsTestDriver()
        let withoutSupport = driver.model()
        XCTAssertFalse(withoutSupport.showsSupport)
        XCTAssertNil(withoutSupport.navigation.support)
        let withSupport = driver.model(support: { driver.calls.append("support") })
        XCTAssertTrue(withSupport.showsSupport)
        withSupport.navigation.support?()
        XCTAssertEqual(driver.calls, ["support"])
    }

    @MainActor
    func testSignOutCapabilityAndFailureRetry() async {
        let driver = AccountSettingsTestDriver()
        await driver.model(allowsSignOut: false).signOut()
        XCTAssertTrue(driver.calls.isEmpty)
        let model = driver.model()
        driver.failure = ProfileActionError(code: .unavailable)
        await model.signOut()
        XCTAssertEqual(driver.calls, ["signOut"])
        XCTAssertNotNil(model.data)
        XCTAssertEqual(model.failedOperation, .signOut)
        driver.failure = nil
        await model.retry()
        XCTAssertEqual(driver.calls, ["signOut", "signOut", "signedOut"])
    }

    @MainActor
    func testLocalAndServerLastLinkRefusalAndSuccessfulDisconnect() async {
        let driver = AccountSettingsTestDriver()
        driver.data = .init(githubConnected: true, discoveryOn: true, linkCount: 1, githubRepositoryCount: 1)
        let refused = driver.model()
        await refused.disconnect()
        XCTAssertTrue(refused.lastLinkRefused)
        XCTAssertTrue(driver.calls.isEmpty)
        driver.data.discoveryOn = false
        let model = driver.model()
        driver.failure = LinkActionError(code: .prerequisiteMissing, details: ["link"])
        await model.disconnect()
        XCTAssertTrue(model.lastLinkRefused)
        XCTAssertEqual(model.data?.githubConnected, true)
        driver.failure = nil
        await model.retry()
        XCTAssertEqual(model.data?.githubConnected, false)
        XCTAssertNil(model.error)
        XCTAssertEqual(driver.calls, ["disconnect", "disconnect"])
    }

    func testSettingsListOrderAndOptionalDiagnostics() {
        let expected: [AccountSettingsListEntry] = [.discovery, .visibility, .dailyReport, .blockedUsers, .account, .legal]
        XCTAssertEqual(AccountSettingsListComposition.entries(hasDiagnostics: false), expected)
        XCTAssertEqual(AccountSettingsListComposition.entries(hasDiagnostics: true), expected + [.diagnostics])
    }

    @MainActor
    func testSettingsListOmitsEveryUnsuppliedDestinationAndKeepsProfileOffList() {
        var destinations = AccountSettingsListNavigationActions()
        XCTAssertEqual(AccountSettingsListComposition.entries(destinations: destinations), [.discovery, .visibility])
        let rows: [AccountSettingsListEntry] = [.dailyReport, .blockedUsers, .account, .legal, .diagnostics]
        for entry in rows {
            let onlyDestination: AccountSettingsListNavigationActions
            switch entry {
            case .dailyReport: onlyDestination = .init(dailyReport: {})
            case .blockedUsers: onlyDestination = .init(blockedUsers: {})
            case .account: onlyDestination = .init(account: {})
            case .legal: onlyDestination = .init(legal: {})
            case .diagnostics: onlyDestination = .init(diagnostics: {})
            default: return XCTFail("Unexpected optional row")
            }
            XCTAssertEqual(AccountSettingsListComposition.entries(destinations: onlyDestination), [.discovery, .visibility, entry])
        }
        var calls: [String] = []
        destinations.dailyReport = { calls.append("report") }
        destinations.blockedUsers = { calls.append("blocked") }
        destinations.account = { calls.append("account") }
        destinations.legal = { calls.append("legal") }
        destinations.diagnostics = { calls.append("diagnostics") }
        XCTAssertEqual(AccountSettingsListComposition.entries(destinations: destinations),
                       [.discovery, .visibility, .dailyReport, .blockedUsers, .account, .legal, .diagnostics])
        destinations.dailyReport(); destinations.blockedUsers(); destinations.account(); destinations.legal(); destinations.diagnostics?()
        XCTAssertEqual(calls, ["report", "blocked", "account", "legal", "diagnostics"])
    }
}

@MainActor
private final class AccountSettingsTestDriver {
    var data = AccountSettingsData(githubConnected: true, linkCount: 2, githubRepositoryCount: 1)
    var calls: [String] = []
    var failure: (any Error)?
    var reloadFailure: (any Error)?
    var accountState: AccountSettingsAccountState?
    var deleted = true
    var duringDeletion: (@MainActor () async -> Void)?
    var duringReload: (@MainActor () async -> Void)?
    func model(allowsSignOut: Bool = true, support: (@MainActor () -> Void)? = nil) -> AccountSettingsModel {
        AccountSettingsModel(data: data, allowsSignOut: allowsSignOut, actions: .init(load: {
            self.calls.append("load"); try self.check(); return self.data
        }, disconnectGitHub: {
            self.calls.append("disconnect"); try self.check()
            self.data.githubConnected = false; return self.data
        }, signOut: {
            self.calls.append("signOut"); try self.check()
        }, deleteAccount: {
            self.calls.append("delete"); await self.duringDeletion?(); try self.check(); return self.deleted
        }, reloadAccount: {
            self.calls.append("reloadAccount"); await self.duringReload?()
            if let failure = self.reloadFailure { throw failure }
            return self.accountState ?? .present(self.data)
        }, resumeParticipation: { self.calls.append("resume") },
        suspendParticipation: { self.calls.append("suspend") }), navigation: .init(
            back: { self.calls.append("back") }, signedOut: { self.calls.append("signedOut") }, discovery: {}, support: support))
    }
    private func check() throws { if let failure { throw failure } }
}

final class AccountSettingsStringsTests: XCTestCase {
    func testBothLanguagesDefineEveryKey() throws {
        for language in ["ja", "en"] {
            let table = try AccountSettingsStrings.table(language: language)
            XCTAssertEqual(Set(table.keys), Set(AccountSettingsString.allCases.map(\.rawValue)))
            for key in AccountSettingsString.allCases {
                let value = try XCTUnwrap(table[key.rawValue])
                XCTAssertFalse(value.isEmpty)
                XCTAssertEqual(AccountSettingsStrings.localized(key.rawValue, language: language), value)
            }
        }
        XCTAssertEqual(AccountSettingsStrings.localized("disconnectExplanation", language: "en"),
            "Disconnecting makes links verified through this account unverified and removes repository link cards read through it.")
        XCTAssertEqual(AccountSettingsStrings.localized("deletionConfirmation", language: "en"),
            "Your personal data is deleted immediately and permanently. This cannot be undone. The only safety exception is that we keep a one-way hash of your Apple account identifier, operator moderation outcomes and blocks other people placed on your account for the period stated in the privacy policy. The hash cannot be turned back into your Apple identifier. If you sign up again with the same Apple identity, we re-apply those outcomes and blocks. Nothing else survives: no name, profile field, link, token, encounter or contact detail. A block is dropped when the person who placed it deletes their own account.")
        XCTAssertEqual(AccountSettingsStrings.localized("deletionConfirmation", language: "ja"),
            "個人データはすぐに完全削除され、元に戻せません。安全のための唯一の例外として、Appleアカウント識別子を元に戻せない一方向ハッシュにした値と、運営者の対応結果、他の人があなたに設定したブロックだけを、プライバシーポリシーに記載した期間保存します。同じAppleアカウントで再登録すると、対応結果とブロックを再適用します。それ以外は何も残りません。名前、プロフィール項目、リンク、トークン、すれちがい、連絡先は保存しません。ブロックした人が自分のアカウントを削除すると、そのブロックも削除します。")
    }
}
