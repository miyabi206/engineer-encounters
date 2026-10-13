import Combine
import CoreBluetooth
import EncounterUI
import Foundation

/// S06's composition policy, shared by the root and hosted tests.
struct ProductDiscoverState: Equatable {
    let feed: DiscoverFeedContent
    let bluetooth: DiscoverBluetoothContent
    let showsSample: Bool

    static func select(discoveryOn: Bool, isAuthorized: Bool, state: DiscoverLoadState,
                       hasCards: Bool, bluetooth: DiscoverBluetoothStatus, isNewUser: Bool, sampleDismissed: Bool) -> Self {
        let feed = DiscoverFeedContent.select(discoveryOn: discoveryOn, isAuthorized: isAuthorized, state: state, hasCards: hasCards)
        return Self(feed: feed, bluetooth: discoveryOn ? DiscoverBluetoothContent.select(bluetooth) : .hidden,
            showsSample: !sampleDismissed && (feed == .discoveryOff ? isNewUser : feed == .empty || feed == .failure))
    }

    static func bluetoothStatus(permission: BluetoothPermissionState, requested: Bool) -> DiscoverBluetoothStatus {
        switch permission {
        case .available: .available
        case .poweredOff: .poweredOff
        case .denied: .denied
        case .unavailable: .unavailable
        case .notRequested: requested ? .checking : .failed
        }
    }

    static func sessionRoute(discoveryOn: Bool, sessionActive: Bool, bluetooth: DiscoverBluetoothStatus) -> ProductRoute? {
        guard discoveryOn else { return nil }
        return sessionActive || bluetooth == .available ? .session : .bluetooth
    }
}

@MainActor
final class ProductPresentationModel: ObservableObject {
    @Published private(set) var ownState: DiscoverLoadState
    @Published private var bluetoothCheckFailed = false
    private let composition: AppComposition
    private let settings: SettingsModel
    private let bluetoothAuthorization: @MainActor () -> CBManagerAuthorization
    private var subscriptions: Set<AnyCancellable> = []

    init(composition: AppComposition, settings: SettingsModel,
         bluetoothAuthorization: @escaping @MainActor () -> CBManagerAuthorization = { CBManager.authorization }) {
        self.composition = composition; self.settings = settings; self.bluetoothAuthorization = bluetoothAuthorization
        ownState = composition.account.profileIsStale ? .failed : .loaded
        composition.account.$profileIsStale.sink { [weak self] stale in
            self?.ownState = stale ? .failed : .loaded
        }.store(in: &subscriptions)
    }

    var bluetooth: DiscoverBluetoothStatus {
        if bluetoothCheckFailed { return .failed }
        var permission = AccountFlowModel.permission(composition.status)
        if permission == .notRequested, bluetoothAuthorization() == .denied || bluetoothAuthorization() == .restricted {
            permission = .denied
        }
        return ProductDiscoverState.bluetoothStatus(permission: permission, requested: composition.runtime?.hasRequestedBluetooth == true)
    }
    var discoveryOn: Bool { composition.discoverAdapter.model?.discoveryOn ?? settings.profile.discoveryOn }
    var sessionActive: Bool { if case .active = composition.sessionAdapter.state { return true }; return false }
    var discoverState: ProductDiscoverState {
        let model = composition.discoverAdapter.model
        return ProductDiscoverState.select(discoveryOn: model?.discoveryOn ?? false, isAuthorized: model?.isAuthorized ?? false,
            state: model?.feedState ?? .idle, hasCards: model?.feed.isEmpty == false, bluetooth: bluetooth,
            isNewUser: composition.sampleEncounter.isNewUser, sampleDismissed: composition.sampleEncounter.isDismissed)
    }

    func retryOwnState() async {
        ownState = .loading
        let epoch = composition.account.sessionGeneration
        do {
            let profile = try await composition.account.loadOwnProfile()
            guard epoch == composition.account.sessionGeneration else { return }
            settings.receive(profile: profile, bluetooth: AccountFlowModel.permission(composition.status))
            ownState = .loaded
        } catch { if epoch == composition.account.sessionGeneration { ownState = .failed } }
    }

    var requiresBluetoothCheck: Bool { composition.runtime?.hasRequestedBluetooth != true && bluetooth == .failed }
    // S06 supplies its explicit permission panel in this state; all button routes still use the real status.
    var feedBluetooth: DiscoverBluetoothStatus { requiresBluetoothCheck ? .available : bluetooth }

    /// Package panels also invoke Retry when foregrounding; that must never prompt for permission.
    func retryBluetooth(in tab: ProductTab) async {
        let epoch = composition.account.sessionGeneration, fence = composition.account.backendCallFence()
        guard fence.isCurrent(), composition.account.state.isSignedIn else { return }
        await composition.refresh()
        guard fence.isCurrent(), epoch == composition.account.sessionGeneration, composition.account.state.isSignedIn else { return }
        bluetoothDidChange(in: tab)
    }

    func requestBluetooth(in tab: ProductTab) async {
        let epoch = composition.account.sessionGeneration, fence = composition.account.backendCallFence()
        guard fence.isCurrent(), composition.account.state.isSignedIn else { return }
        bluetoothCheckFailed = false
        // Recover storage first; a failed preparation must be retryable from this action too.
        await composition.refresh()
        guard fence.isCurrent(), epoch == composition.account.sessionGeneration, composition.account.state.isSignedIn else { return }
        if composition.runtime?.hasRequestedBluetooth != true, bluetooth != .denied {
            do { try await composition.requestBluetooth() }
            catch {
                if fence.isCurrent(), epoch == composition.account.sessionGeneration { bluetoothCheckFailed = true }
                return
            }
        }
        guard fence.isCurrent(), epoch == composition.account.sessionGeneration else { return }
        await retryBluetooth(in: tab)
    }

    func bluetoothDidChange(in tab: ProductTab) {
        if bluetooth == .available { composition.productNavigation.bluetoothRecovered(in: tab) }
    }

    func myCardNavigation(_ tab: ProductTab) -> MyCardNavigationActions {
        let navigation = composition.productNavigation
        return .init(editProfile: { navigation.push(.profile, in: tab) }, links: { navigation.push(.links, in: tab) },
            visibility: { navigation.push(.visibility, in: tab) })
    }

    func openSession(in tab: ProductTab) {
        guard let route = ProductDiscoverState.sessionRoute(discoveryOn: discoveryOn,
            sessionActive: sessionActive, bluetooth: bluetooth) else {
            composition.productNavigation.showDiscoveryOff(in: tab); return
        }
        if route == .bluetooth { composition.productNavigation.showBluetooth(forSession: true, in: tab) }
        else { composition.productNavigation.push(route, in: tab) }
    }
    func openQR(in tab: ProductTab) {
        if discoveryOn { composition.productNavigation.push(.qr, in: tab) }
        else { composition.productNavigation.showDiscoveryOff(in: tab) }
    }
    func openFavorites(in tab: ProductTab) {
        if discoveryOn { composition.productNavigation.push(.favorites, in: tab) }
        else { composition.productNavigation.showDiscoveryOff(in: tab) }
    }
    func accountNavigation(_ tab: ProductTab) -> AccountSettingsNavigationActions {
        let navigation = self.composition.productNavigation
        let composition = self.composition
        var actions = AccountSettingsNavigationActions(back: { navigation.back(in: tab) },
            signedOut: { if !composition.account.state.isSignedIn { navigation.reset() } },
            discovery: { navigation.push(.discovery, in: tab) })
        if SettingsSafetyAdapter.hasSupport() { actions.support = { navigation.push(.legal, in: tab) } }
        return actions
    }
    func settingsDestinations() -> AccountSettingsListNavigationActions {
        let navigation = self.composition.productNavigation
        var destinations = AccountSettingsListNavigationActions(
            dailyReport: { navigation.push(.dailyReport, in: .settings) },
            blockedUsers: { navigation.push(.blockedUsers, in: .settings) },
            account: { navigation.push(.account, in: .settings) }, legal: { navigation.push(.legal, in: .settings) })
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        destinations.diagnostics = { navigation.push(.diagnostics, in: .settings) }
        #endif
        return destinations
    }
    func settingsNavigation(_ tab: ProductTab) -> SettingsNavigationActions {
        let navigation = self.composition.productNavigation
        return .init(back: { navigation.back(in: tab) }, editProfile: { navigation.push(.profile, in: tab) },
              discovery: { navigation.push(.discovery, in: tab) }, visibility: { navigation.push(.visibility, in: tab) },
              links: { navigation.push(.links, in: tab) }, bluetoothRecovery: { self.composition.productNavigation.showBluetooth(forSession: false, in: tab) })
    }
    func discoverNavigation(_ tab: ProductTab) -> DiscoverNavigationActions {
        let navigation = self.composition.productNavigation
        let safetyAdapter = self.composition.settingsSafetyAdapter
        return .init(openEncounter: { navigation.push(.encounter($0), in: tab) }, openFavorites: { self.openFavorites(in: tab) },
              openSession: { self.openSession(in: tab) }, openQR: { self.openQR(in: tab) },
              openDiscoverySettings: { navigation.push(.discovery, in: tab) }, openProfileEditing: { navigation.push(.profile, in: tab) },
              openReportOrBlock: { id in safetyAdapter.presentReport(id.id, linkID: nil,
                  completed: { navigation.encounterRemoved(in: tab) }) },
              reportImpersonation: { id, link in safetyAdapter.presentReport(id.id, linkID: link,
                  completed: { navigation.encounterRemoved(in: tab) }) },
              openSample: { navigation.push(.sample, in: tab) }, openOwnLinks: { navigation.push(.links, in: tab) },
              openSystemSettings: AccountFlowModel.openBluetoothSettings,
              openBluetoothRecovery: { self.composition.productNavigation.showBluetooth(forSession: true, in: tab) },
              back: { navigation.back(in: tab) }, encounterRemoved: { navigation.encounterRemoved(in: tab) })
    }
    func sessionNavigation(_ tab: ProductTab) -> SessionNavigationActions {
        let navigation = self.composition.productNavigation
        let discoverAdapter = self.composition.discoverAdapter
        return .init(openQR: { self.openQR(in: tab) }, openEncounter: { navigation.push(.encounter($0), in: tab) },
              close: { navigation.back(in: tab) }, openDiscoveryOff: {
                  discoverAdapter.model?.receiveAccess(discoveryOn: false, isAuthorized: true)
                  navigation.showDiscoveryOff(in: tab)
              })
    }
    func qrNavigation(_ tab: ProductTab) -> QRNavigationActions {
        let navigation = self.composition.productNavigation
        let discoverAdapter = self.composition.discoverAdapter
        return .init(openEncounter: { navigation.showEncounter($0, in: tab) }, openIOSSettings: AccountFlowModel.openBluetoothSettings,
              close: { navigation.back(in: tab) }, openDiscoveryOff: {
                  discoverAdapter.model?.receiveAccess(discoveryOn: false, isAuthorized: true)
                  navigation.showDiscoveryOff(in: tab)
              })
    }
}
