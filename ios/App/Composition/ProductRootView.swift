import EncounterUI
import SwiftUI
import UIKit

@MainActor
struct ProductRootView: View {
    @ObservedObject var settings: SettingsModel
    let links: LinksModel?
    @ObservedObject var composition: AppComposition
    @ObservedObject private var discoverAdapter: DiscoverAdapter
    @ObservedObject private var sessionAdapter: SessionAdapter
    @ObservedObject private var navigation: ProductNavigationModel

    init(settings: SettingsModel, links: LinksModel?, composition: AppComposition) {
        self.settings = settings; self.links = links; self.composition = composition
        discoverAdapter = composition.discoverAdapter; sessionAdapter = composition.sessionAdapter
        navigation = composition.productNavigation
    }

    var body: some View {
        ProductTabContainer(navigation: navigation, discover: stack(.discover), profile: stack(.profile), settings: stack(.settings))
            .task {
                if !settings.hasLoadedInterests { await settings.loadInterests() }
                discoverAdapter.interests = settings.interests
            }
            .onChange(of: settings.interests) { _, interests in discoverAdapter.interests = interests }
    }

    private func stack(_ tab: ProductTab) -> some View {
        NavigationStack(path: Binding(get: { navigation.path(for: tab) }, set: { path in
            switch tab { case .discover: navigation.discover = path; case .profile: navigation.profile = path; case .settings: navigation.settings = path }
        })) {
            root(tab)
                .navigationDestination(for: ProductRoute.self) { route in destination(route, tab: tab) }
        }
    }

    @ViewBuilder private func root(_ tab: ProductTab) -> some View {
        switch tab {
        case .discover:
            if let model = discoverAdapter.model {
                DiscoverFeedView(model: model, sample: composition.sampleEncounter, navigation: discoverNavigation(.discover),
                    interests: ownInterests, sessionActive: sessionActive, bluetooth: bluetooth,
                    prerequisites: settings.profile.prerequisites, ownState: composition.account.profileIsStale ? .failed : .loaded,
                    retryOwnState: { await composition.refresh() }, retryBluetooth: { await composition.refresh() })
            } else { ProgressView() }
        case .profile:
            // Profile uses the existing editor until the later unit supplies the own-card S11.
            EditProfileView(model: settings, navigation: settingsNavigation(.profile))
        case .settings:
            SettingsListView(navigation: settingsNavigation(.settings)) {
                Button(AccountStrings.text("links")) { navigation.push(.links, in: .settings) }
                #if DEVELOPMENT_BUILD || INTERNAL_BUILD
                Button(DiagnosticsStrings.text("title")) { navigation.push(.diagnostics, in: .settings) }
                #endif
            }
        }
    }

    @ViewBuilder private func destination(_ route: ProductRoute, tab: ProductTab) -> some View {
        switch route {
        case .encounter(let id):
            if let model = discoverAdapter.model {
                EncounterDetailView(encounterID: id, model: model, viewerPurposes: settings.profile.purposes,
                    viewerInterestIDs: settings.profile.interestIDs, navigation: discoverNavigation(tab))
            }
        case .favorites:
            if let model = discoverAdapter.model {
                DiscoverFavoritesView(model: model, sample: composition.sampleEncounter, navigation: discoverNavigation(tab),
                    prerequisites: settings.profile.prerequisites, ownState: composition.account.profileIsStale ? .failed : .loaded,
                    retryOwnState: { await composition.refresh() })
            }
        case .sample: SampleEncounterDetailView(sample: composition.sampleEncounter, navigation: discoverNavigation(tab))
        case .session:
            if let discover = discoverAdapter.model {
                ProductSessionView(adapter: sessionAdapter, discover: discover, navigation: sessionNavigation(tab))
            }
        case .qr: ProductQRView(adapter: composition.qrAdapter, navigation: qrNavigation(tab))
        case .profile: EditProfileView(model: settings, navigation: settingsNavigation(tab))
        case .discovery: DiscoveryAndMatchingView(model: settings, navigation: settingsNavigation(tab))
        case .visibility: VisibilitySettingsView(model: settings, navigation: settingsNavigation(tab))
        case .links:
            if let links {
                AccountLinksView(model: links, adapter: composition.linkAdapter,
                    back: { navigation.back(in: tab) }, discovery: { navigation.push(.discovery, in: tab) })
            }
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        case .diagnostics: ProductDiagnosticsDestination(composition: composition)
        #endif
        case .bluetooth:
            DiscoverBluetoothUnavailablePanel(status: bluetooth, discoveryOn: settings.profile.discoveryOn,
                navigation: discoverNavigation(tab), retry: { await composition.refresh() })
        }
    }

    private var ownInterests: [InterestOption] { settings.interests.filter { settings.profile.interestIDs.contains($0.id) } }
    private var sessionActive: Bool { if case .active = sessionAdapter.state { return true }; return false }
    private var bluetooth: DiscoverBluetoothStatus {
        switch AccountFlowModel.permission(composition.status) {
        case .available: .available
        case .poweredOff: .poweredOff
        case .denied: .denied
        case .unavailable: .unavailable
        case .notRequested: .checking
        }
    }
    private func settingsNavigation(_ tab: ProductTab) -> SettingsNavigationActions {
        .init(back: { navigation.back(in: tab) }, editProfile: { navigation.push(.profile, in: tab) },
              discovery: { navigation.push(.discovery, in: tab) }, visibility: { navigation.push(.visibility, in: tab) },
              links: { navigation.push(.links, in: tab) }, bluetoothRecovery: AccountFlowModel.openBluetoothSettings)
    }
    private func discoverNavigation(_ tab: ProductTab) -> DiscoverNavigationActions {
        .init(openEncounter: { navigation.push(.encounter($0), in: tab) }, openFavorites: { navigation.push(.favorites, in: tab) },
              openSession: { navigation.push(.session, in: tab) }, openQR: { navigation.push(.qr, in: tab) },
              openDiscoverySettings: { navigation.push(.discovery, in: tab) }, openProfileEditing: { navigation.push(.profile, in: tab) },
              // Optional safety/report/delete actions stay absent until the safety unit.
              openReportOrBlock: nil, reportImpersonation: nil,
              openSample: { navigation.push(.sample, in: tab) }, openOwnLinks: { navigation.push(.links, in: tab) },
              openSystemSettings: AccountFlowModel.openBluetoothSettings,
              openBluetoothRecovery: { navigation.push(.session, in: tab) },
              back: { navigation.back(in: tab) }, encounterRemoved: { navigation.encounterRemoved(in: tab) })
    }
    private func sessionNavigation(_ tab: ProductTab) -> SessionNavigationActions {
        .init(openQR: { navigation.push(.qr, in: tab) }, openEncounter: { navigation.push(.encounter($0), in: tab) },
              close: { navigation.back(in: tab) }, openDiscoveryOff: {
                  discoverAdapter.model?.receiveAccess(discoveryOn: false, isAuthorized: true)
                  navigation.showDiscoveryOff(in: tab)
              })
    }
    private func qrNavigation(_ tab: ProductTab) -> QRNavigationActions {
        .init(openEncounter: { navigation.showEncounter($0, in: tab) }, openIOSSettings: AccountFlowModel.openBluetoothSettings,
              close: { navigation.back(in: tab) }, openDiscoveryOff: {
                  discoverAdapter.model?.receiveAccess(discoveryOn: false, isAuthorized: true)
                  navigation.showDiscoveryOff(in: tab)
              })
    }
}

@MainActor
private struct ProductSessionView: View {
    @StateObject private var presentation = ProductSessionPresentation()
    @ObservedObject var discover: DiscoverModel
    let navigation: SessionNavigationActions
    private let adapter: SessionAdapter

    init(adapter: SessionAdapter, discover: DiscoverModel, navigation: SessionNavigationActions) {
        self.adapter = adapter; self.discover = discover; self.navigation = navigation
    }
    var body: some View {
        Group {
            if let model = presentation.model {
                SessionView(model: model, navigation: navigation, hasRevealedEncounters: !cards.isEmpty) {
                    ForEach(cards) { item in
                        Button { navigation.openEncounter(item.id) } label: {
                            VStack(alignment: .leading) {
                                if let name = item.card.displayName { Text(name) }
                                if let introduction = item.card.introduction { Text(introduction) }
                                if let link = item.card.links.first { Text(link.title) }
                                Text(item.day.formatted(locale: .current))
                            }
                        }
                    }
                }
            } else { ProgressView() }
        }
        .task {
            await presentation.open(adapter: adapter, navigation: navigation)
            await discover.loadFeed()
        }
    }
    private var cards: [EncounterFeedCard] { discover.feed.filter { $0.card.kind == .session } }
}

@MainActor
private final class ProductSessionPresentation: ObservableObject {
    @Published private(set) var model: SessionModel?
    func open(adapter: SessionAdapter, navigation: SessionNavigationActions) async {
        guard model == nil else { return }
        let state = await adapter.presentationState()
        model = SessionModel(state: state, actions: adapter.actions(), navigation: navigation)
    }
}

@MainActor
private struct ProductQRView: View {
    @StateObject private var model: QRModel
    let navigation: QRNavigationActions
    init(adapter: QRAdapter, navigation: QRNavigationActions) {
        self.navigation = navigation
        _model = StateObject(wrappedValue: adapter.makeModel(navigation: navigation))
    }
    var body: some View { QRView(model: model, navigation: navigation) }
}

/// UIKit supplies an actual reselect event, including a tap on the already-selected tab.
/// Each hosting controller contains its own SwiftUI NavigationStack and state.
@MainActor
private struct ProductTabContainer<Discover: View, Profile: View, Settings: View>: UIViewControllerRepresentable {
    @ObservedObject var navigation: ProductNavigationModel
    let discover: Discover
    let profile: Profile
    let settings: Settings

    func makeCoordinator() -> Coordinator { Coordinator(navigation: navigation) }
    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        controller.delegate = context.coordinator
        let discoverHost = UIHostingController(rootView: discover)
        let profileHost = UIHostingController(rootView: profile)
        let settingsHost = UIHostingController(rootView: settings)
        discoverHost.tabBarItem = UITabBarItem(title: AccountStrings.text("discoverTab"), image: UIImage(systemName: "sparkles"), tag: 0)
        profileHost.tabBarItem = UITabBarItem(title: AccountStrings.text("profileTab"), image: UIImage(systemName: "person.crop.circle"), tag: 1)
        settingsHost.tabBarItem = UITabBarItem(title: AccountStrings.text("settingsTab"), image: UIImage(systemName: "gearshape"), tag: 2)
        controller.viewControllers = [discoverHost, profileHost, settingsHost]
        return controller
    }
    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        (controller.viewControllers?[0] as? UIHostingController<Discover>)?.rootView = discover
        (controller.viewControllers?[1] as? UIHostingController<Profile>)?.rootView = profile
        (controller.viewControllers?[2] as? UIHostingController<Settings>)?.rootView = settings
        controller.selectedIndex = Self.tabs.firstIndex(of: navigation.selection) ?? 0
    }
    private static var tabs: [ProductTab] { [.discover, .profile, .settings] }
    @MainActor
    final class Coordinator: NSObject, UITabBarControllerDelegate {
        let navigation: ProductNavigationModel
        init(navigation: ProductNavigationModel) { self.navigation = navigation }
        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            navigation.select(ProductTabContainer.tabs[tabBarController.selectedIndex])
        }
    }
}
