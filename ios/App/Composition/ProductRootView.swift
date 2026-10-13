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
    @ObservedObject private var safetyAdapter: SettingsSafetyAdapter
    @StateObject private var presentation: ProductPresentationModel
    @ObservedObject private var navigation: ProductNavigationModel

    init(settings: SettingsModel, links: LinksModel?, composition: AppComposition) {
        _presentation = StateObject(wrappedValue: ProductPresentationModel(composition: composition, settings: settings))
        self.settings = settings; self.links = links; self.composition = composition
        discoverAdapter = composition.discoverAdapter; sessionAdapter = composition.sessionAdapter
        navigation = composition.productNavigation
        safetyAdapter = composition.settingsSafetyAdapter
    }

    var body: some View {
        ProductTabContainer(navigation: navigation, lifecycle: composition.productLifecycle, discover: stack(.discover), profile: stack(.profile), settings: stack(.settings))
            .task {
                if !settings.hasLoadedInterests { await settings.loadInterests() }
                discoverAdapter.interests = settings.interests
            }
            .onChange(of: settings.interests) { _, interests in discoverAdapter.interests = interests }
            .sheet(item: Binding(get: { safetyAdapter.sheet }, set: { _ in })) { presentation in
                SafetyReportSheet(model: presentation.model)
            }
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
                ProductDiscoverAccessView(adapter: discoverAdapter) {
                    if presentation.discoverState.feed == .discoveryOff {
                        ScrollView {
                            DiscoverDiscoveryOffPanel(sample: composition.sampleEncounter, prerequisites: settings.profile.prerequisites,
                                state: presentation.ownState, navigation: presentation.discoverNavigation(.discover),
                                retry: { await presentation.retryOwnState() }).padding()
                        }
                        .navigationTitle(AccountStrings.text("discoverTab"))
                        .task { await model.loadFeed() }
                    } else {
                        VStack(spacing: 0) {
                            if presentation.requiresBluetoothCheck {
                                ProductBluetoothPermissionPanel(presentation: presentation, tab: .discover,
                                    navigation: presentation.discoverNavigation(.discover)).padding()
                            }
                            DiscoverFeedView(model: model, sample: composition.sampleEncounter, navigation: presentation.discoverNavigation(.discover),
                                interests: ownInterests, sessionActive: presentation.sessionActive, bluetooth: presentation.feedBluetooth,
                                prerequisites: settings.profile.prerequisites, ownState: presentation.ownState,
                                retryOwnState: { await presentation.retryOwnState() }, retryBluetooth: { await presentation.retryBluetooth(in: .discover) })
                        }
                    }
                }
            } else { ProgressView() }
        case .profile:
            ProductMyCardView(adapter: safetyAdapter, navigation: presentation.myCardNavigation(.profile))
        case .settings:
            SettingsListView(navigation: presentation.settingsNavigation(.settings), destinations: presentation.settingsDestinations())
        }
    }

    @ViewBuilder private func destination(_ route: ProductRoute, tab: ProductTab) -> some View {
        switch route {
        case .encounter(let id):
            if let model = discoverAdapter.model {
                ProductDiscoverAccessView(adapter: discoverAdapter) {
                    EncounterDetailView(encounterID: id, model: model, viewerPurposes: settings.profile.purposes,
                        viewerInterestIDs: settings.profile.interestIDs, navigation: presentation.discoverNavigation(tab))
                }
            }
        case .favorites:
            if let model = discoverAdapter.model {
                ProductDiscoverAccessView(adapter: discoverAdapter) {
                    DiscoverFavoritesView(model: model, sample: composition.sampleEncounter, navigation: presentation.discoverNavigation(tab),
                        prerequisites: settings.profile.prerequisites, ownState: presentation.ownState,
                        retryOwnState: { await presentation.retryOwnState() })
                }
            }
        case .sample: SampleEncounterDetailView(sample: composition.sampleEncounter, navigation: presentation.discoverNavigation(tab))
        case .session:
            if let discover = discoverAdapter.model {
                ProductSessionView(adapter: sessionAdapter, discover: discover, poller: composition.confirmationPoller, navigation: presentation.sessionNavigation(tab))
            }
        case .qr: ProductQRView(adapter: composition.qrAdapter, poller: composition.confirmationPoller, navigation: presentation.qrNavigation(tab))
        case .dailyReport:
            ProductReportSettingsView(adapter: safetyAdapter, navigation: .init(back: { navigation.back(in: tab) },
                systemSettings: AccountFlowModel.openBluetoothSettings))
        case .blockedUsers:
            ProductBlockedView(adapter: safetyAdapter, navigation: .init(back: { navigation.back(in: tab) }))
        case .account:
            ProductAccountSettingsView(composition: composition, navigation: presentation.accountNavigation(tab))
        case .legal:
            ProductLegalView(navigation: .init(back: { navigation.back(in: tab) }))
        case .profile: EditProfileView(model: settings, navigation: presentation.settingsNavigation(tab))
        case .discovery: DiscoveryAndMatchingView(model: settings, navigation: presentation.settingsNavigation(tab))
        case .visibility: VisibilitySettingsView(model: settings, navigation: presentation.settingsNavigation(tab))
        case .links:
            if let links {
                AccountLinksView(model: links, adapter: composition.linkAdapter,
                    back: { navigation.back(in: tab) }, discovery: { navigation.push(.discovery, in: tab) })
            }
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        case .diagnostics: ProductDiagnosticsDestination(composition: composition)
        #endif
        case .bluetooth:
            Group {
                if presentation.requiresBluetoothCheck {
                    ProductBluetoothPermissionPanel(presentation: presentation, tab: tab, navigation: presentation.discoverNavigation(tab)).padding()
                } else {
                    DiscoverBluetoothUnavailablePanel(status: presentation.bluetooth, discoveryOn: presentation.discoveryOn,
                        navigation: presentation.discoverNavigation(tab), retry: { await presentation.retryBluetooth(in: tab) })
                }
            }
            .onChange(of: presentation.bluetooth) { _, _ in presentation.bluetoothDidChange(in: tab) }
        }
    }

    private var ownInterests: [InterestOption] { settings.interests.filter { settings.profile.interestIDs.contains($0.id) } }

}

@MainActor
private struct ProductSessionView: View {
    @StateObject private var presentation = ProductSessionPresentation()
    @ObservedObject var discover: DiscoverModel
    let navigation: SessionNavigationActions
    private let adapter: SessionAdapter
    private let poller: EncounterConfirmationPoller

    init(adapter: SessionAdapter, discover: DiscoverModel, poller: EncounterConfirmationPoller, navigation: SessionNavigationActions) {
        self.adapter = adapter; self.discover = discover; self.poller = poller; self.navigation = navigation
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
            guard !Task.isCancelled else { return }
            await poller.openSession()
        }
        .onDisappear { poller.closeSession() }
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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: QRModel
    @StateObject private var presentation = ProductQRPresentation()
    private let poller: EncounterConfirmationPoller
    let navigation: QRNavigationActions
    init(adapter: QRAdapter, poller: EncounterConfirmationPoller, navigation: QRNavigationActions) {
        self.navigation = navigation; self.poller = poller
        _model = StateObject(wrappedValue: adapter.makeModel(navigation: navigation))
    }
    var body: some View {
        Group {
            if presentation.ready { QRView(model: model, navigation: navigation) }
            else { ProgressView() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, !presentation.ready else { return }
            await poller.openQR(model)
            guard !Task.isCancelled else { return }
            presentation.ready = true
        }
        .onDisappear { poller.closeQR(model) }
    }
}

@MainActor
private final class ProductQRPresentation: ObservableObject {
    @Published var ready = false
}

/// UIKit supplies an actual reselect event, including a tap on the already-selected tab.
/// Each hosting controller contains its own SwiftUI NavigationStack and state.
@MainActor
struct ProductTabContainer<Discover: View, Profile: View, Settings: View>: UIViewControllerRepresentable {
    @ObservedObject var navigation: ProductNavigationModel
    @ObservedObject var lifecycle: ProductSceneLifecycle
    let discover: Discover
    let profile: Profile
    let settings: Settings

    func makeCoordinator() -> Coordinator { Coordinator(navigation: navigation) }
    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        controller.delegate = context.coordinator
        let discoverHost = UIHostingController(rootView: AnyView(discover.environment(\.scenePhase, lifecycle.phase)))
        let profileHost = UIHostingController(rootView: AnyView(profile.environment(\.scenePhase, lifecycle.phase)))
        let settingsHost = UIHostingController(rootView: AnyView(settings.environment(\.scenePhase, lifecycle.phase)))
        discoverHost.tabBarItem = UITabBarItem(title: AccountStrings.text("discoverTab"), image: UIImage(systemName: "sparkles"), tag: 0)
        profileHost.tabBarItem = UITabBarItem(title: AccountStrings.text("profileTab"), image: UIImage(systemName: "person.crop.circle"), tag: 1)
        settingsHost.tabBarItem = UITabBarItem(title: AccountStrings.text("settingsTab"), image: UIImage(systemName: "gearshape"), tag: 2)
        controller.viewControllers = [discoverHost, profileHost, settingsHost]
        return controller
    }
    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        (controller.viewControllers?[0] as? UIHostingController<AnyView>)?.rootView = AnyView(discover.environment(\.scenePhase, lifecycle.phase))
        (controller.viewControllers?[1] as? UIHostingController<AnyView>)?.rootView = AnyView(profile.environment(\.scenePhase, lifecycle.phase))
        (controller.viewControllers?[2] as? UIHostingController<AnyView>)?.rootView = AnyView(settings.environment(\.scenePhase, lifecycle.phase))
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


@MainActor
private struct ProductMyCardView: View {
    @StateObject private var model: MyCardModel
    init(adapter: SettingsSafetyAdapter, navigation: MyCardNavigationActions) {
        _model = StateObject(wrappedValue: MyCardModel(actions: adapter.myCardActions(), navigation: navigation))
    }
    var body: some View { MyCardView(model: model) }
}

@MainActor
private struct ProductReportSettingsView: View {
    @StateObject private var model: ReportSettingsModel
    init(adapter: SettingsSafetyAdapter, navigation: ReportSettingsNavigationActions) {
        _model = StateObject(wrappedValue: ReportSettingsModel(pushAvailable: false, permission: .unavailable,
            actions: adapter.reportSettingsActions(), navigation: navigation))
    }
    var body: some View { ReportSettingsView(model: model, notificationControlsEnabled: false) }
}

@MainActor
private struct ProductBlockedView: View {
    @StateObject private var model: SafetyBlockedModel
    init(adapter: SettingsSafetyAdapter, navigation: SafetyBlockedNavigationActions) {
        _model = StateObject(wrappedValue: SafetyBlockedModel(actions: adapter.blockedActions(), navigation: navigation))
    }
    var body: some View { SafetyBlockedUsersView(model: model) }
}

@MainActor
private struct ProductLegalView: View {
    @StateObject private var model: LegalModel
    init(navigation: LegalNavigationActions) {
        _model = StateObject(wrappedValue: LegalModel(data: SettingsSafetyAdapter.legalData(),
            actions: SettingsSafetyAdapter.legalActions(), navigation: navigation))
    }
    var body: some View { LegalView(model: model) }
}

@MainActor
struct ProductDiscoverAccessView<Content: View>: View {
    @ObservedObject var adapter: DiscoverAdapter
    @ViewBuilder let content: () -> Content
    var body: some View {
        if adapter.needsAuthorizationRetry, adapter.model?.discoveryOn == true {
            VStack(spacing: 16) {
                Text(AccountStrings.text("profileError"))
                Button(AccountStrings.text("retry")) { Task { await adapter.retryAuthorization() } }
            }.padding()
        } else { content() }
    }
}

/// Only an explicit tap creates a permission observer. Foreground rechecks use the package panel after it exists.
@MainActor
private struct ProductBluetoothPermissionPanel: View {
    @ObservedObject var presentation: ProductPresentationModel
    let tab: ProductTab
    let navigation: DiscoverNavigationActions
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AccountStrings.text("bluetoothUnavailable")).font(.headline)
            Text(AccountStrings.text("bluetoothCheckGuidance"))
            Button(AccountStrings.text("checkBluetooth")) { Task { await presentation.requestBluetooth(in: tab) } }
            if presentation.discoveryOn { Button(AccountStrings.text("qrExchange"), action: navigation.openQR) }
            Button(AccountStrings.text("discoverySettings"), action: navigation.openDiscoverySettings)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
