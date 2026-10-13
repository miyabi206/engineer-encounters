import Combine
import Foundation

/// Independent tab histories, with encounter origins retained by the stack itself.
enum ProductTab: Hashable { case discover, profile, settings }
enum ProductRoute: Hashable {
    case encounter(String), favorites, sample, session, qr, profile, discovery, visibility, links, bluetooth, dailyReport, blockedUsers, account, legal
    #if DEVELOPMENT_BUILD || INTERNAL_BUILD
    case diagnostics
    #endif
}

@MainActor
final class ProductNavigationModel: ObservableObject {
    @Published private(set) var selection: ProductTab = .discover
    private var bluetoothSessionOrigins: Set<ProductTab> = []
    @Published var discover: [ProductRoute] = []
    @Published var profile: [ProductRoute] = []
    @Published var settings: [ProductRoute] = []

    func select(_ tab: ProductTab) {
        if selection == tab { setPath([], for: tab) }
        selection = tab
    }
    func push(_ route: ProductRoute, in tab: ProductTab) { setPath(path(for: tab) + [route], for: tab) }
    func back(in tab: ProductTab) {
        var path = path(for: tab)
        if !path.isEmpty { path.removeLast() }
        setPath(path, for: tab)
    }
    func encounterRemoved(in tab: ProductTab) {
        let path = path(for: tab)
        guard let index = path.lastIndex(where: { if case .encounter = $0 { return true }; return false }) else { return }
        // S06 or the originating S10; a QR/session route must not trap a missing card.
        if let origin = path[..<index].lastIndex(of: .favorites) { setPath(Array(path[...origin]), for: tab) }
        else { setPath([], for: tab) }
    }
    func showEncounter(_ id: String, in tab: ProductTab) {
        var path = path(for: tab)
        if path.last == .qr { path.removeLast() }
        setPath(path + [.encounter(id)], for: tab)
    }
    func showSessionFromSurface() {
        bluetoothSessionOrigins.remove(.discover)
        setPath([.session], for: .discover)
        selection = .discover
    }
    func showBluetoothFromSurface() {
        setPath([], for: .discover)
        selection = .discover
        showBluetooth(forSession: true, in: .discover)
    }
    func showDiscoveryOff(in tab: ProductTab) { setPath([], for: tab); selection = .discover }
    func showBluetooth(forSession: Bool, in tab: ProductTab) {
        if forSession { bluetoothSessionOrigins.insert(tab) } else { bluetoothSessionOrigins.remove(tab) }
        if path(for: tab).last != .bluetooth { push(.bluetooth, in: tab) }
    }
    func bluetoothRecovered(in tab: ProductTab) {
        guard path(for: tab).last == .bluetooth else { return }
        back(in: tab)
        if bluetoothSessionOrigins.remove(tab) != nil { push(.session, in: tab) }
    }
    func reset() { bluetoothSessionOrigins = []; discover = []; profile = []; settings = []; selection = .discover }
    func path(for tab: ProductTab) -> [ProductRoute] {
        switch tab { case .discover: discover; case .profile: profile; case .settings: settings }
    }
    private func setPath(_ path: [ProductRoute], for tab: ProductTab) {
        switch tab { case .discover: discover = path; case .profile: profile = path; case .settings: settings = path }
    }
}
