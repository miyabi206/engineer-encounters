import Combine
import EncounterUI
import Foundation
import UIKit

enum AccountRoot: Equatable { case welcome, loadingProfile, profileUnavailable, onboarding, settings }

@MainActor
final class AccountFlowModel: ObservableObject {
    @Published private(set) var root: AccountRoot = .welcome
    @Published private(set) var onboarding: OnboardingModel?
    @Published private(set) var settings: SettingsModel?
    @Published private(set) var profileError: ProfileActionError?
    @Published private(set) var bluetooth: BluetoothPermissionState = .notRequested
    private let composition: AppComposition
    private let defaults: UserDefaults
    private var accountID: UUID?
    private var started = false
    private var subscriptions: Set<AnyCancellable> = []
    private var radioSubscription: AnyCancellable?

    init(composition: AppComposition, defaults: UserDefaults = .standard) {
        self.composition = composition
        self.defaults = defaults
        composition.account.$state.removeDuplicates().sink { [weak self] state in
            guard let self, self.started else { return }
            Task { await self.receive(state: state) }
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

    func start() async {
        guard !started else { return }
        await composition.waitForRestoration()
        guard !started else { return }
        started = true
        await receive(state: composition.account.state)
    }

    func refresh() async {
        guard started, composition.account.state.isSignedIn else { return }
        await loadProfile()
    }

    func resumeOnboarding() {
        guard canResumeOnboarding, let profile = composition.account.profile else { return }
        makeModels(profile: profile)
    }

    private func receive(state: AccountState) async {
        // Ignore a state queued before a newer session transition.
        guard state == composition.account.state else { return }
        guard case .signedIn(let id) = state else {
            accountID = nil
            onboarding = nil
            settings = nil
            profileError = nil
            root = .welcome
            return
        }
        guard accountID != id else { return }
        accountID = id
        onboarding = nil
        settings = nil
        profileError = nil
        root = .loadingProfile
        await loadProfile()
    }

    private func loadProfile() async {
        guard let id = accountID, composition.account.state == .signedIn(id) else { return }
        do {
            let profile = try await composition.account.loadOwnProfile()
            guard accountID == id, composition.account.state == .signedIn(id) else { return }
            profileError = nil
            if settings == nil { makeModels(profile: profile) }
            else { receive(profile: profile) }
        } catch is CancellationError {
        } catch {
            guard accountID == id, composition.account.state == .signedIn(id) else { return }
            profileError = error as? ProfileActionError ?? .init(code: .unavailable)
            if settings == nil { root = .profileUnavailable }
        }
    }

    private func makeModels(profile: OwnProfileState) {
        guard let id = accountID else { return }
        let completed = defaults.bool(forKey: Self.completionKey(id))
        let actions = composition.account.profileActions(bluetoothState: { [weak self] in
            self?.bluetooth ?? .unavailable
        }) { [weak self] in
            guard let self else { throw ProfileActionError(code: .unavailable) }
            try await self.composition.requestBluetooth()
            return self.bluetooth
        }
        settings = SettingsModel(profile: profile, actions: actions, bluetooth: bluetooth,
            onboardingExplanationCompleted: completed, allowsDiscoveryActivation: false)
        if completed {
            onboarding = nil
            root = .settings
        } else {
            onboarding = OnboardingModel(profile: profile, bluetooth: bluetooth, actions: actions,
                onExit: { [weak self] in self?.root = .welcome },
                onFinish: { [weak self] _ in self?.finishOnboarding(for: id) },
                onBluetoothRecovery: Self.openBluetoothSettings)
            root = .onboarding
        }
    }

    private func finishOnboarding(for id: UUID) {
        guard accountID == id, composition.account.state == .signedIn(id) else { return }
        defaults.set(true, forKey: Self.completionKey(id))
        // Rebuild Settings so S16 knows that the S05 explanation has been completed.
        if let profile = composition.account.profile { makeModels(profile: profile) }
    }

    private func receive(profile: OwnProfileState) {
        guard let id = accountID, composition.account.state == .signedIn(id) else { return }
        onboarding?.receive(profile: profile, bluetooth: bluetooth)
        settings?.receive(profile: profile, bluetooth: bluetooth)
    }

    private func receive(bluetooth: BluetoothPermissionState) {
        self.bluetooth = bluetooth
        if let profile = composition.account.profile { receive(profile: profile) }
    }

    static func completionKey(_ id: UUID) -> String { "encounter.onboarding.completed.\(id.uuidString.lowercased())" }

    static func permission(_ status: EncounterRuntimeStatus) -> BluetoothPermissionState {
        switch status.radioAvailability {
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
