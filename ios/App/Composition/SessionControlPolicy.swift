import EncounterUI
import Foundation

/// The control's decisions are independent of intents, ActivityKit and UI rendering.
enum SessionControlRoute: Equatable {
    case blocked, welcome, onboarding, retry, discoveryOff, bluetooth, session, start
}

struct SessionControlContext {
    var deletionSuspended: Bool
    var signedIn: Bool
    var accountReady: Bool
    var onboardingComplete: Bool
    var profileReady: Bool
    var discoveryOn: Bool
    var bluetooth: BluetoothPermissionState
    var sessionActive: Bool

    var route: SessionControlRoute {
        if deletionSuspended { return .blocked }
        if !signedIn { return .welcome }
        if sessionActive { return .session }
        if !profileReady { return .retry }
        if !onboardingComplete { return .onboarding }
        if !accountReady { return .retry }
        if !discoveryOn { return .discoveryOff }
        if bluetooth != .available { return .bluetooth }
        return .start
    }
}

extension AppComposition {
    func startSessionFromControl() async {
        guard !sessionControlInProgress else { return }
        sessionControlInProgress = true
        defer { sessionControlInProgress = false }
        await accountFlow.start()
        guard !deletionSuspended else { return }
        if sessionAdapter.controlNeedsAccountRefresh { await accountFlow.refresh() }
        guard !deletionSuspended else { return }
        // Expire the holder even if its timer could not execute while suspended.
        let epoch = account.sessionGeneration
        let state = await sessionAdapter.presentationState()
        guard epoch == account.sessionGeneration else { return }
        let active: Bool
        if case .active = state { active = true } else { active = false }
        let completed: Bool
        if case .signedIn(let id) = account.state { completed = account.onboardingCompletion.contains(id) }
        else { completed = false }
        let ready: Bool
        if case .signedIn = account.state { ready = !account.sessionChangeInProgress && account.hasCurrentSessionContext &&
                account.profile?.declarationsRecorded == true && account.profile?.timeZone.isEmpty == false &&
                account.profile?.moderationState == "active" }
        else { ready = false }
        let context = SessionControlContext(deletionSuspended: deletionSuspended,
            signedIn: account.state.isSignedIn, accountReady: ready,
            onboardingComplete: completed, profileReady: account.profile != nil && !account.profileIsStale,
            discoveryOn: account.profile?.discoveryOn == true,
            bluetooth: AccountFlowModel.permission(status), sessionActive: active)
        switch context.route {
        case .blocked, .welcome: return // The root already presents the blocking/welcome state.
        case .onboarding: accountFlow.resumeOnboarding()
        case .retry:
            sessionAdapter.refuseControlStart()
            if accountFlow.root == .settings { showSessionFromSurface() }
        case .discoveryOff:
            productNavigation.showDiscoveryOff(in: .discover)
        case .bluetooth:
            productNavigation.showBluetoothFromSurface()
        case .session: showSessionFromSurface()
        case .start:
            let epoch = account.sessionGeneration
            await sessionAdapter.startFromControl()
            guard epoch == account.sessionGeneration, !deletionSuspended, accountFlow.root == .settings else { return }
            showSessionFromSurface()
        }
    }

    func openSessionFromActivity() async {
        await accountFlow.start()
        guard !deletionSuspended else { return }
        if accountFlow.root == .settings { showSessionFromSurface() }
    }

    private func showSessionFromSurface() {
        productNavigation.showSessionFromSurface()
    }

    func stopSessionFromActivity(sessionID: String) async {
        await waitForRestoration()
        guard !deletionSuspended else { return }
        let epoch = account.sessionGeneration
        let fence = account.backendCallFence()
        var state = await sessionAdapter.presentationState()
        // Process loss restores no active claim: verify the current account's session
        // before honoring a surviving button. Existing queued stops retain their get fence.
        if case .active = state {} else {
            state = (try? await sessionAdapter.actions().refreshSession()) ?? .none
        }
        guard fence.isCurrent(), epoch == account.sessionGeneration, !deletionSuspended,
              case .active(let session) = state, session.sessionID == sessionID else { return }
        try? await sessionAdapter.actions().stopSession()
    }
}

enum SessionSurfaceStrings {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: "SessionActivity")
    }
}
