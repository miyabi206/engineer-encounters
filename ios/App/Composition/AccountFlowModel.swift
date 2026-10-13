import Combine
import EncounterUI
import Foundation
import UIKit

enum AccountRoot: Equatable { case restoring, welcome, loadingProfile, profileUnavailable, onboarding, settings }

@MainActor
final class AccountFlowModel: ObservableObject {
    @Published private(set) var root: AccountRoot = .welcome
    @Published private(set) var onboarding: OnboardingModel?
    @Published private(set) var settings: SettingsModel?
    @Published private(set) var links: LinksModel?
    @Published private(set) var profileError: ProfileActionError?
    @Published private(set) var bluetooth: BluetoothPermissionState = .notRequested
    @Published private(set) var savedWithStaleProfile = false
    private let composition: AppComposition
    let completion: OnboardingCompletionStore
    private var accountID: UUID?
    private var started = false
    private var restorationFinished = false
    private var startupTask: Task<Void, Never>?
    private var profileTask: (id: UUID, task: Task<Void, Never>)?
    private var profileLoadVersion: UInt = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var radioSubscription: AnyCancellable?

    init(composition: AppComposition, defaults: UserDefaults? = nil) {
        self.composition = composition
        completion = defaults.map { OnboardingCompletionStore(defaults: $0) } ?? composition.account.onboardingCompletion
        switch composition.account.state {
        case .restoring, .signedInPending: root = .restoring
        default: root = .welcome
        }
        composition.account.$state.removeDuplicates().sink { [weak self] state in
            guard let self, self.started else { return }
            self.receive(state: state)
        }.store(in: &subscriptions)
        composition.account.$profileIsStale.sink { [weak self] stale in
            self?.savedWithStaleProfile = stale
        }.store(in: &subscriptions)
        composition.account.$profile.sink { [weak self] profile in
            guard let self, let profile else { return }
            self.receive(profile: profile)
        }.store(in: &subscriptions)
        composition.$runtime.sink { [weak self] runtime in
            guard let self else { return }
            self.radioSubscription = runtime?.$status.sink { [weak self] status in
                self?.receive(bluetooth: Self.permission(status))
            }
            if runtime == nil { self.receive(bluetooth: .notRequested) }
        }.store(in: &subscriptions)
    }

    var usesSignInWelcome: Bool { BuildKind.isDevelopment && composition.account.state == .signedOut }
    var canResumeOnboarding: Bool { composition.account.state.isSignedIn && accountID != nil && root == .welcome }
    var offersDiagnostics: Bool { BuildKind.isDevelopment || BuildKind.isInternal }

    deinit { startupTask?.cancel(); profileTask?.task.cancel() }

    func start() async {
        if startupTask == nil {
            started = true
            startupTask = Task { [weak self] in
                guard let self else { return }
                await self.composition.waitForRestoration()
                self.restorationFinished = true
                self.receive(state: self.composition.account.state)
                await self.profileTask?.task.value
            }
        }
        // Awaiting a model-owned task does not transfer the view's cancellation to it.
        await startupTask?.value
        await profileTask?.task.value
    }

    func refresh() async {
        guard started, !composition.account.deletionSuspended else { return }
        let previousProfileLoadVersion = profileLoadVersion
        await composition.refresh()
        guard composition.account.state.isSignedIn else { return }
        receive(state: composition.account.state)
        if case .signedIn = composition.account.state {
            // Recovery's state notification may already have loaded the profile,
            // even if its task finished while composition was still refreshing.
            if profileLoadVersion == previousProfileLoadVersion { beginProfileLoad() }
            await profileTask?.task.value
        }
    }

    func resumeOnboarding() {
        guard canResumeOnboarding, let profile = composition.account.profile else { return }
        makeModels(profile: profile)
    }

    private func receive(state: AccountState) {
        guard case .signedIn(let id) = state else {
            profileTask?.task.cancel()
            profileTask = nil
            accountID = nil
            onboarding = nil
            settings = nil
            links = nil
            profileError = nil
            switch state {
            case .restoring: root = .restoring
            case .signedInPending: root = restorationFinished ? .profileUnavailable : .restoring
            default:
                if state == .signedOut { completion.clear() }
                root = .welcome
            }
            return
        }
        guard accountID != id else { return }
        accountID = id
        onboarding = nil
        settings = nil
        links = nil
        profileError = nil
        root = .loadingProfile
        // Published sends before state is assigned. The task starts after this synchronous transition.
        beginProfileLoad()
    }

    private func beginProfileLoad() {
        guard profileTask == nil else { return }
        profileLoadVersion &+= 1
        let id = UUID()
        let epoch = composition.account.sessionGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadProfile(epoch: epoch)
            if self.profileTask?.id == id { self.profileTask = nil }
        }
        profileTask = (id, task)
    }

    private func loadProfile(epoch: UUID) async {
        guard let id = accountID, composition.account.state == .signedIn(id), composition.account.sessionGeneration == epoch else { return }
        do {
            let profile = try await composition.account.loadOwnProfile()
            guard accountID == id, composition.account.state == .signedIn(id), composition.account.sessionGeneration == epoch else { return }
            profileError = nil
            if settings == nil { makeModels(profile: profile) }
            else { receive(profile: profile) }
        } catch {
            guard accountID == id, composition.account.state == .signedIn(id), composition.account.sessionGeneration == epoch else { return }
            profileError = error as? ProfileActionError ?? .init(code: .unavailable)
            if settings == nil { root = .profileUnavailable }
        }
    }

    private static func allowsDiscoveryActivation(_ profile: OwnProfileState) -> Bool {
        profile.declarationsRecorded && !profile.timeZone.isEmpty && profile.moderationState == "active"
    }

    private func profileActions() -> ProfileActions {
        composition.account.profileActions(bluetoothState: { [weak self] in
            self?.bluetooth ?? .unavailable
        }) { [weak self] in
            guard let self else { throw ProfileActionError(code: .unavailable) }
            try await self.composition.requestBluetooth()
            return self.bluetooth
        }
    }

    private func makeModels(profile: OwnProfileState) {
        guard let id = accountID else { return }
        let epoch = composition.account.sessionGeneration
        let completed = completion.contains(id)
        let actions = profileActions()
        let linkActions = composition.linkAdapter.actions()
        links = LinksModel(actions: linkActions, discoveryOn: profile.discoveryOn)
        settings = SettingsModel(profile: profile, actions: actions, bluetooth: bluetooth,
            onboardingExplanationCompleted: completed, allowsDiscoveryActivation: Self.allowsDiscoveryActivation(profile))
        if completed {
            onboarding = nil
            root = .settings
        } else {
            onboarding = OnboardingModel(profile: profile, bluetooth: bluetooth, actions: actions,
                onExit: { [weak self] in
                    guard let self, self.composition.account.sessionGeneration == epoch else { return }
                    self.root = .welcome
                },
                onFinish: { [weak self] _ in
                    guard let self, self.composition.account.sessionGeneration == epoch else { return }
                    self.finishOnboarding(for: id)
                },
                onBluetoothRecovery: Self.openBluetoothSettings, linkActions: linkActions)
            root = .onboarding
        }
    }

    private func finishOnboarding(for id: UUID) {
        guard accountID == id, composition.account.state == .signedIn(id) else { return }
        completion.finish(id)
        // Rebuild Settings so S16 knows that the S05 explanation has been completed.
        if let profile = composition.account.profile { makeModels(profile: profile) }
    }

    private func receive(profile: OwnProfileState) {
        guard let id = accountID, composition.account.state == .signedIn(id) else { return }
        onboarding?.receive(profile: profile, bluetooth: bluetooth)
        settings?.receive(allowsDiscoveryActivation: Self.allowsDiscoveryActivation(profile))
        settings?.receive(profile: profile, bluetooth: bluetooth)
        links?.discoveryOn = profile.discoveryOn
    }

    private func receive(bluetooth: BluetoothPermissionState) {
        self.bluetooth = bluetooth
        if let profile = composition.account.profile { receive(profile: profile) }
    }

    static func permission(_ status: EncounterRuntimeStatus) -> BluetoothPermissionState {
        if status.bluetoothPoweredOff { return .poweredOff }
        return switch status.radioAvailability {
        case .unknown: .notRequested
        case .available: .available
        case .unauthorized: .denied
        case .unavailable: .unavailable
        }
    }

    static func openBluetoothSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
