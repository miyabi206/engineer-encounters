import Combine
import EncounterUI
import SwiftUI
import UIKit

private typealias ProductPanelState<Value> = State<Value>

/// Reserve only the measured content height, up to the space available for this panel.
@MainActor
struct ProductFittingPanel<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @ProductPanelState private var contentHeight: CGFloat?

    var body: some View {
        ScrollView { content() }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, height in
                contentHeight = height
            }
            .frame(height: min(contentHeight ?? maxHeight, maxHeight))
            .scrollDisabled(contentHeight.map { $0 <= maxHeight } ?? false)
            .scrollBounceBehavior(.basedOnSize)
    }
}

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
        .tint(EncounterPalette.accent)
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
                                retry: { await presentation.retryOwnState() })
                                .padding(.horizontal, 20).padding(.vertical, 16)
                        }
                        .background(EncounterPalette.background.ignoresSafeArea())
                        .navigationTitle(AccountStrings.text("discoverTab"))
                        .task { await model.loadFeed() }
                    } else {
                        GeometryReader { geometry in
                            VStack(spacing: 0) {
                                if presentation.requiresBluetoothCheck {
                                    ProductFittingPanel(maxHeight: geometry.size.height * 0.75) {
                                        ProductBluetoothPermissionPanel(presentation: presentation, tab: .discover,
                                            navigation: presentation.discoverNavigation(.discover))
                                            .padding(.horizontal, 20).padding(.vertical, 16)
                                    }
                                }
                                DiscoverFeedView(model: model, sample: composition.sampleEncounter, navigation: presentation.discoverNavigation(.discover),
                                    interests: ownInterests, sessionActive: presentation.sessionActive, bluetooth: presentation.feedBluetooth,
                                    prerequisites: settings.profile.prerequisites, ownState: presentation.ownState,
                                    retryOwnState: { await presentation.retryOwnState() }, retryBluetooth: { await presentation.retryBluetooth(in: .discover) })
                            }
                        }
                        .background(EncounterPalette.background.ignoresSafeArea())
                    }
                }
            } else { EncounterProgress(AccountStrings.text("loadingProfile")) }
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
                ProductSessionView(adapter: sessionAdapter, discover: discover, poller: composition.confirmationPoller, navigation: presentation.sessionNavigation(tab), retryStart: { await composition.startSessionFromControl() })
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
            ScrollView {
                VStack(spacing: 16) {
                    if presentation.requiresBluetoothCheck {
                        ProductBluetoothPermissionPanel(presentation: presentation, tab: tab, navigation: presentation.discoverNavigation(tab))
                    } else {
                        DiscoverBluetoothUnavailablePanel(status: presentation.bluetooth, discoveryOn: presentation.discoveryOn,
                            navigation: presentation.discoverNavigation(tab), retry: { await presentation.retryBluetooth(in: tab) })
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            .background(EncounterPalette.background.ignoresSafeArea())
            .onChange(of: presentation.bluetooth) { _, _ in presentation.bluetoothDidChange(in: tab) }
        }
    }

    private var ownInterests: [InterestOption] { settings.interests.filter { settings.profile.interestIDs.contains($0.id) } }

}

@MainActor
private struct ProductSessionView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var presentation = ProductSessionPresentation()
    @ObservedObject var discover: DiscoverModel
    let navigation: SessionNavigationActions
    @ObservedObject private var adapter: SessionAdapter
    private let poller: EncounterConfirmationPoller
    private let retryStart: @MainActor () async -> Void

    init(adapter: SessionAdapter, discover: DiscoverModel, poller: EncounterConfirmationPoller, navigation: SessionNavigationActions, retryStart: @escaping @MainActor () async -> Void) {
        self.adapter = adapter; self.discover = discover; self.poller = poller; self.navigation = navigation
        self.retryStart = retryStart
    }
    var body: some View {
        Group {
            if let failure = adapter.controlStartFailure {
                GeometryReader { geometry in
                    VStack(spacing: 16) {
                        ProductFittingPanel(maxHeight: geometry.size.height / 2) {
                            EncounterSurfaceCard {
                                EncounterNotice(SessionSurfaceStrings.text(failure == .offline ? "startOffline" : "startFailed"), kind: .warning)
                                Button(AccountStrings.text("retry")) { Task { await retryStart() } }
                                    .buttonStyle(EncounterButtonStyle(.secondary))
                                    .disabled(adapter.controlStartInProgress)
                                Button(AccountStrings.text("back"), action: navigation.close)
                                    .buttonStyle(EncounterButtonStyle(.tertiary))
                            }
                            .padding(.horizontal, 20).padding(.vertical, 16)
                        }
                        if adapter.state == .stopping || adapter.state == .starting { sessionContent }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .background(EncounterPalette.background.ignoresSafeArea())
                .navigationTitle(SessionSurfaceStrings.text("session"))
            } else { sessionContent }
        }
        .task {
            await presentation.open(adapter: adapter, navigation: navigation)
            guard !Task.isCancelled else { return }
            await poller.openSession()
        }
        .onChange(of: adapter.controlStartFailure) { _, failure in
            if failure == nil { Task { await presentation.reload(adapter: adapter, navigation: navigation) } }
        }
        .onDisappear { poller.closeSession(); adapter.clearControlStartFailure() }
    }
    @ViewBuilder private var sessionContent: some View {
        if let model = presentation.model {
            SessionView(model: model, navigation: navigation, hasRevealedEncounters: !cards.isEmpty) {
                let firstCardID = cards.first?.id
                ForEach(cards) { item in
                    if item.id != firstCardID { Divider().overlay(EncounterPalette.border) }
                    Button { navigation.openEncounter(item.id) } label: {
                        VStack(alignment: .leading, spacing: 16) {
                            let layout = dynamicTypeSize.isAccessibilitySize ?
                                AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) :
                                AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                            layout {
                                if let name = item.card.displayName {
                                    EncounterAvatar(displayName: name, decorative: true)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    if let name = item.card.displayName { Text(name).font(.headline) }
                                    if let introduction = item.card.introduction {
                                        Text(introduction).foregroundStyle(EncounterPalette.inkSecondary)
                                    }
                                    if let link = item.card.links.first {
                                        Text(link.title).font(.headline).foregroundStyle(EncounterPalette.accent)
                                    }
                                    Text(item.day.formatted(locale: .current)).font(.caption)
                                        .foregroundStyle(EncounterPalette.inkSecondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").foregroundStyle(EncounterPalette.inkSecondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .foregroundStyle(EncounterPalette.ink)
                        .multilineTextAlignment(.leading)
                        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }.buttonStyle(.plain)
                }
            }
        } else { EncounterProgress(AccountStrings.text("loadingProfile")) }
    }
    private var cards: [EncounterFeedCard] { discover.feed.filter { $0.card.kind == .session } }
}

@MainActor
final class ProductSessionPresentation: ObservableObject {
    @Published private(set) var model: SessionModel?
    private var subscription: AnyCancellable?
    func reload(adapter: SessionAdapter, navigation: SessionNavigationActions) async {
        subscription = nil
        model = nil
        await open(adapter: adapter, navigation: navigation)
    }
    func open(adapter: SessionAdapter, navigation: SessionNavigationActions) async {
        guard model == nil else { return }
        _ = await adapter.presentationState()
        guard subscription == nil else { return }
        // The shared adapter publishes holder snapshots. Every scene follows those
        // snapshots rather than keeping the acknowledgement from its first visit.
        subscription = adapter.$state.removeDuplicates().sink { [weak self, weak adapter] state in
            guard let self, let adapter else { return }
            self.model = SessionModel(state: state, actions: adapter.actions(), navigation: navigation)
        }
    }
}

@MainActor
struct ProductQRView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: QRModel
    @StateObject private var presentation = ProductQRPresentation()
    private let adapter: QRAdapter
    private let poller: EncounterConfirmationPoller
    let navigation: QRNavigationActions
    init(adapter: QRAdapter, poller: EncounterConfirmationPoller, navigation: QRNavigationActions) {
        self.navigation = navigation; self.poller = poller; self.adapter = adapter
        _model = StateObject(wrappedValue: adapter.makeModel(navigation: navigation))
    }
    var body: some View {
        Group {
            if presentation.ready { QRView(model: model, navigation: navigation) }
            else { EncounterProgress(AccountStrings.text("loadingProfile")) }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            adapter.showPresentation(model)
            await poller.openQR(model)
            guard !Task.isCancelled else { return }
            presentation.ready = true
        }
        .onDisappear {
            presentation.ready = false
            poller.closeQR(model)
            model.disappear()
        }
        .onChange(of: model.segment) { _, segment in
            if segment == .scan {
                model.disappear()
                Task { await model.appear() }
            }
        }
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
        controller.tabBar.tintColor = EncounterPalette.accentUIColor
        let discoverHost = UIHostingController(rootView: AnyView(discover.environment(\.scenePhase, lifecycle.phase)))
        let profileHost = UIHostingController(rootView: AnyView(profile.environment(\.scenePhase, lifecycle.phase)))
        let settingsHost = UIHostingController(rootView: AnyView(settings.environment(\.scenePhase, lifecycle.phase)))
        discoverHost.tabBarItem = UITabBarItem(title: AccountStrings.text("discoverTab"), image: UIImage(systemName: "magnifyingglass"), tag: 0)
        profileHost.tabBarItem = UITabBarItem(title: AccountStrings.text("profileTab"), image: UIImage(systemName: "person"), selectedImage: UIImage(systemName: "person.fill"))
        settingsHost.tabBarItem = UITabBarItem(title: AccountStrings.text("settingsTab"), image: UIImage(systemName: "gearshape"), selectedImage: UIImage(systemName: "gearshape.fill"))
        profileHost.tabBarItem.tag = 1
        settingsHost.tabBarItem.tag = 2
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
            ScrollView {
                EncounterSurfaceCard {
                    EncounterSymbolTile(symbol: "exclamationmark.shield")
                    Text(AccountStrings.text("profileError")).font(.headline)
                    Button(AccountStrings.text("retry")) { Task { await adapter.retryAuthorization() } }
                        .buttonStyle(EncounterButtonStyle(.primary))
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(EncounterPalette.background.ignoresSafeArea())
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
        EncounterSurfaceCard {
            EncounterSymbolTile(symbol: "antenna.radiowaves.left.and.right.slash")
            Text(AccountStrings.text("bluetoothUnavailable")).font(.headline)
            Text(AccountStrings.text("bluetoothCheckGuidance")).foregroundStyle(EncounterPalette.inkSecondary)
            Button(AccountStrings.text("checkBluetooth")) { Task { await presentation.requestBluetooth(in: tab) } }
                .buttonStyle(EncounterButtonStyle(.primary))
            if presentation.discoveryOn {
                Button(AccountStrings.text("qrExchange"), action: navigation.openQR)
                    .buttonStyle(EncounterButtonStyle(.secondary))
            }
            Button(AccountStrings.text("discoverySettings"), action: navigation.openDiscoverySettings)
                .buttonStyle(EncounterButtonStyle(.tertiary))
        }
    }
}
