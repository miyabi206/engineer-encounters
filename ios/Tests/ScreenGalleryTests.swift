import AuthenticationServices
import EncounterUI
import Foundation
import SwiftUI
import UIKit
import XCTest

/// Opt in on the hosted test process with ENCOUNTERS_SCREEN_GALLERY=/absolute/output/directory.
/// Use separate directories with xcodebuild -testLanguage ja / en; localization follows the run.
/// No app composition or live services are constructed by this gallery.
@MainActor
final class ScreenGalleryTests: XCTestCase {
    func testScreenGallery() async throws {
        guard let path = ProcessInfo.processInfo.environment["ENCOUNTERS_SCREEN_GALLERY"],
              path.hasPrefix("/") else {
            throw XCTSkip("Set ENCOUNTERS_SCREEN_GALLERY to an absolute directory to render the gallery.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = try appBackendWindowScene()
        for screen in screens {
            for variant in GalleryVariant.allCases {
                // Rebuild models for every image so task loads and local drafts cannot leak between variants.
                let content = try await screen.make()
                try await render(content, screen: screen, variant: variant, scene: scene, directory: directory)
            }
        }
    }

    private func render(_ content: GalleryContent, screen: GalleryScreen, variant: GalleryVariant,
                        scene: UIWindowScene, directory: URL) async throws {
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let size = CGSize(width: 393, height: variant == .axfull ? 2700 : (variant == .full ? 2400 : 852))
        let root = Group {
            if screen.navigation { NavigationStack { content.view } }
            else { content.view }
        }
        .environment(\.colorScheme, variant == .dark ? .dark : .light)
        .environment(\.dynamicTypeSize, variant == .ax || variant == .axfull ? .accessibility2 : .large)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = variant == .dark ? .dark : .light
        window.backgroundColor = .systemBackground
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.setNeedsLayout()
        window.layoutIfNeeded()
        // Yield the main actor so the public views' .task loads can finish against the stubs.
        try await Task.sleep(for: .seconds(1))
        content.afterLoad()
        await Task.yield()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertEqual(host.view.bounds.size, size, screen.name)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true),
                          "Could not render \(screen.name)-\(variant.rawValue)")
        }
        let png = try XCTUnwrap(image.pngData(), "Could not encode \(screen.name)")
        try png.write(to: directory.appendingPathComponent("\(screen.name)-\(variant.rawValue).png"))
    }

    private var screens: [GalleryScreen] {
        [
            GalleryScreen("s01-welcome-plain", navigation: false) {
                GalleryContent(WelcomeView(declarations: .constant(.init()), onTerms: {}, onPrivacy: {},
                                           onRetry: {}) { GallerySignInButton() })
            },
            GalleryScreen("s01-welcome-error", navigation: false) {
                GalleryContent(WelcomeView(
                    declarations: .constant(.init(isAdult: true, acceptsTermsAndPrivacy: true)),
                    error: .init(code: .unavailable), onTerms: {}, onPrivacy: {}, onRetry: {}) {
                        GallerySignInButton()
                    })
            },
            GalleryScreen("s02-basics-empty") {
                GalleryContent(ProfileBasicsView(model: GalleryFixtures.onboarding(profile: .init())))
            },
            GalleryScreen("s02-basics-filled") {
                let model = GalleryFixtures.onboarding()
                model.edit(.displayName)
                return GalleryContent(ProfileBasicsView(model: model))
            },
            GalleryScreen("s03-interests-selected") {
                let model = GalleryFixtures.onboarding()
                model.edit(.interest)
                return GalleryContent(InterestsAndPurposesView(model: model))
            },
            GalleryScreen("s04-first-link-empty") {
                GalleryContent(FirstLinkView(model: GalleryFixtures.firstLink(links: [])))
            },
            GalleryScreen("s04-first-link-one-link") {
                GalleryContent(FirstLinkView(model: GalleryFixtures.firstLink(links: [GalleryFixtures.links[0]])))
            },
            GalleryScreen("s05-permissions-ready") {
                GalleryContent(DiscoveryPermissionsView(model: GalleryFixtures.onboarding()))
            },
            GalleryScreen("s06-feed-cards") { GalleryFixtures.feed(.cards) },
            GalleryScreen("s06-feed-loading") { GalleryFixtures.feed(.loading) },
            GalleryScreen("s06-feed-error") { GalleryFixtures.feed(.error) },
            GalleryScreen("s06-feed-bluetooth-off-s23") { GalleryFixtures.feed(.bluetoothOff) },
            GalleryScreen("s06-feed-discovery-off-s24") { GalleryFixtures.feed(.discoveryOff) },
            GalleryScreen("s06-feed-empty-s25") { GalleryFixtures.feed(.empty) },
            GalleryScreen("s07-detail-real") {
                GalleryContent(EncounterDetailView(
                    encounterID: GalleryFixtures.cards[0].id, model: GalleryFixtures.discover(),
                    viewerPurposes: [.discovery, .collaboration], viewerInterestIDs: ["ios", "oss"],
                    navigation: GalleryFixtures.discoverNavigation))
            },
            GalleryScreen("s07-detail-sample") {
                GalleryContent(SampleEncounterDetailView(sample: GalleryFixtures.sample(),
                                                        navigation: GalleryFixtures.discoverNavigation))
            },
            GalleryScreen("s08-session-active") { GalleryFixtures.session(ended: false) },
            GalleryScreen("s08-session-ended") { GalleryFixtures.session(ended: true) },
            GalleryScreen("s09-qr-show") { GalleryFixtures.qr(scan: false) },
            GalleryScreen("s09-qr-scan") { GalleryFixtures.qr(scan: true) },
            GalleryScreen("s10-favorites-encounters") { GalleryFixtures.favorites(empty: false) },
            // S10 saved-links is skipped: DiscoverFavoritesView owns a private @State segment
            // initialized to .encounters and exposes no public initializer/binding to select it.
            // Its stub action below still supplies saved links for future public API support.
            GalleryScreen("s10-favorites-empty") { GalleryFixtures.favorites(empty: true) },
            GalleryScreen("s11-my-card-preview") {
                let data = MyCardData(profile: GalleryFixtures.profile, links: GalleryFixtures.links,
                                      interests: GalleryFixtures.interests)
                let model = MyCardModel(actions: .init(load: { data }, openOriginal: { _ in }),
                                        navigation: .init(editProfile: {}, links: {}, visibility: {}))
                return GalleryContent(MyCardView(model: model))
            },
            GalleryScreen("s12-edit-profile-filled") {
                GalleryContent(EditProfileView(model: GalleryFixtures.settings(),
                                               navigation: GalleryFixtures.settingsNavigation))
            },
            GalleryScreen("s13-links-three-links") {
                GalleryContent(LinkListView(model: GalleryFixtures.linksModel(), back: {}, discoverySettings: {}))
            },
            GalleryScreen("s14-add-link-github-connected") {
                let model = GalleryFixtures.linksModel()
                model.beginAdd()
                model.selectedSource = .github
                return GalleryContent(LinkAddView(model: model))
            },
            GalleryScreen("s15-edit-link-filled") {
                let model = GalleryFixtures.linksModel()
                model.beginEdit(GalleryFixtures.links[0])
                return GalleryContent(LinkEditView(model: model, discoverySettings: {}))
            },
            GalleryScreen("s16-discovery-enabled") {
                GalleryContent(DiscoveryAndMatchingView(model: GalleryFixtures.settings(),
                                                        navigation: GalleryFixtures.settingsNavigation))
            },
            GalleryScreen("s17-visibility-configured") {
                GalleryContent(VisibilitySettingsView(model: GalleryFixtures.settings(),
                                                     navigation: GalleryFixtures.settingsNavigation))
            },
            GalleryScreen("settings-list-default") {
                GalleryContent(SettingsListView(navigation: GalleryFixtures.settingsNavigation,
                    destinations: .init(dailyReport: {}, blockedUsers: {}, account: {}, legal: {})))
            },
            GalleryScreen("s18-daily-report-configured") { GalleryFixtures.dailyReport() },
            GalleryScreen("s19-blocked-one-block") { GalleryFixtures.blocked(empty: false) },
            GalleryScreen("s19-blocked-empty") { GalleryFixtures.blocked(empty: true) },
            GalleryScreen("s20-account-connected") { GalleryFixtures.account() },
            GalleryScreen("s21-legal-entries-contact") {
                let model = LegalModel(data: .init(terms: GalleryFixtures.url("terms"),
                    privacy: GalleryFixtures.url("privacy"), support: GalleryFixtures.url("support"),
                    moderationContact: "support@example.org", version: "1.0 (1)"),
                    actions: .init(open: { _ in }, contact: { _ in }, copy: { _ in }),
                    navigation: .init(back: {}))
                return GalleryContent(LegalView(model: model))
            },
            // SafetyReportSheet supplies its own NavigationStack.
            GalleryScreen("s26-report-form", navigation: false) { await GalleryFixtures.report(accepted: false) },
            GalleryScreen("s26-report-accepted", navigation: false) { await GalleryFixtures.report(accepted: true) }
        ]
    }
}

private enum GalleryVariant: String, CaseIterable { case light, dark, ax, full, axfull }

@MainActor
private struct GalleryScreen {
    let name: String
    let navigation: Bool
    let make: @MainActor () async throws -> GalleryContent

    init(_ name: String, navigation: Bool = true,
         make: @escaping @MainActor () async throws -> GalleryContent) {
        self.name = name; self.navigation = navigation; self.make = make
    }
}

@MainActor
private struct GalleryContent {
    let view: AnyView
    let afterLoad: @MainActor () -> Void

    init<V: View>(_ view: V, afterLoad: @escaping @MainActor () -> Void = {}) {
        self.view = AnyView(view); self.afterLoad = afterLoad
    }
}

@MainActor
private struct GallerySignInButton: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        SignInWithAppleButton(.signIn, onRequest: { _ in }, onCompletion: { _ in })
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .allowsHitTesting(false)
    }
}

@MainActor
private final class GalleryDismissalStore: SampleEncounterDismissalStore {
    private(set) var isSampleEncounterDismissed = false
    func dismissSampleEncounter() { isSampleEncounterDismissed = true }
}

@MainActor
private enum GalleryFixtures {
    static func url(_ path: String) -> URL { URL(string: "https://example.com/\(path)")! }

    // Same placeholder catalogue and bilingual labels as EncounterUI's InterimProfileInterests.
    static let interests: [InterestOption] = [
        .init(id: "ios", labelJapanese: "iOS", labelEnglish: "iOS"),
        .init(id: "android", labelJapanese: "Android", labelEnglish: "Android"),
        .init(id: "web", labelJapanese: "Web", labelEnglish: "Web"),
        .init(id: "backend", labelJapanese: "バックエンド", labelEnglish: "Backend"),
        .init(id: "design", labelJapanese: "デザイン", labelEnglish: "Design"),
        .init(id: "oss", labelJapanese: "オープンソース", labelEnglish: "Open source")
    ]
    static let day = EncounterDay(year: 2026, month: 10, day: 13)
    static let previousDay = EncounterDay(year: 2026, month: 10, day: 12)
    static let profile = OwnProfileState(
        displayName: "Aki", introduction: "Building small tools with Swift and sharing what I learn.",
        contactDetail: "aki@example.org", interestIDs: ["ios", "oss"], purposes: [.discovery, .collaboration],
        fieldVisibility: [.displayName: .everyoneEligible, .introduction: .everyoneEligible,
                          .interests: .everyoneEligible, .purposes: .everyoneEligible, .contactDetail: .compatibleOnly],
        discoveryOn: true, linkCount: 3,
        prerequisites: .init(displayName: true, introduction: true, interest: true, link: true),
        declarationsRecorded: true, timeZone: "Asia/Tokyo")

    static var links: [OwnLinkState] {
        [
            .init(id: "link-swift", source: .github, sourceLabel: "GitHub", title: "Swift Notes",
                  description: "A small notebook for ideas and experiments.", mainLanguage: "Swift",
                  tags: ["SwiftUI", "Tools"], openingText: "A notebook that stays simple.",
                  url: url("aki/swift-notes"), visibility: .everyoneEligible, verified: true,
                  displayOrder: 0, sourceItemID: "repo-swift", repositoryName: "aki/swift-notes"),
            .init(id: "link-web", source: .github, sourceLabel: "GitHub", title: "Reading List",
                  description: "Keep useful articles together.", mainLanguage: "TypeScript", tags: ["Web"],
                  url: url("aki/reading-list"), visibility: .compatibleOnly, verified: true,
                  displayOrder: 1, sourceItemID: "repo-web", repositoryName: "aki/reading-list"),
            .init(id: "link-private", source: .other, sourceLabel: "Portfolio", title: "Weekend Sketches",
                  description: "Work in progress.", url: url("aki/sketches"), visibility: .private,
                  verified: false, displayOrder: 2)
        ]
    }

    static var encounterLinks: [EncounterLinkCard] {
        [
            .init(id: "ren-tool", source: "GitHub", title: "Tiny Tasks",
                  description: "A focused task list built with SwiftUI.", tags: ["SwiftUI", "Tools"],
                  mainLanguage: "Swift", openingText: "One small task at a time.",
                  url: url("ren/tiny-tasks"), verified: true),
            .init(id: "ren-notes", source: "Blog", title: "Notes on building tools",
                  description: "Experiments, sketches, and things learned along the way.", tags: ["Design"],
                  url: URL(string: "https://example.org/ren/notes")!, verified: false)
        ]
    }

    static var cards: [EncounterCard] {
        [
            .init(id: "encounter-ren", kind: .ambient, day: day, displayName: "Ren",
                  introduction: "I make useful little apps and contribute to open source.",
                  interests: [interests[0], interests[5]], purposes: [.discovery, .collaboration],
                  contactDetail: "ren@example.org", links: encounterLinks),
            .init(id: "encounter-kei", kind: .session, day: day, displayName: "Kei",
                  introduction: "Exploring the web and accessible interfaces.",
                  interests: [interests[2], interests[4]], purposes: [.collaboration],
                  links: [encounterLinks[1]]),
            .init(id: "encounter-nao", kind: .qr, day: previousDay, displayName: "Nao",
                  introduction: "Small experiments with Swift.", interests: [interests[0]],
                  purposes: [.discovery], links: [encounterLinks[0]])
        ]
    }

    static func profileActions(_ initial: OwnProfileState) -> ProfileActions {
        // Writes remain memory-only even if a control is accidentally activated during a hosted run.
        var current = initial
        return ProfileActions(loadInterests: { interests }, saveProfile: { name, intro, contact in
            current.displayName = name; current.introduction = intro; current.contactDetail = contact
            return current
        }, saveInterests: { ids in current.interestIDs = ids; return current },
           savePurposes: { purposes in current.purposes = purposes; return current },
           setDiscovery: { enabled in current.discoveryOn = enabled; return current },
           requestBluetooth: { .available },
           setMinimumSharedInterests: { count in current.minimumSharedInterests = count; return current },
           setFieldVisibility: { field, visibility in current.fieldVisibility[field] = visibility; return current })
    }

    static func onboarding(profile initial: OwnProfileState = profile) -> OnboardingModel {
        var off = initial; off.discoveryOn = false
        return OnboardingModel(profile: off, interests: interests, actions: profileActions(off),
                               onExit: {}, onFinish: { _ in }, onBluetoothRecovery: {})
    }

    static func firstLink(links: [OwnLinkState]) -> OnboardingModel {
        var off = profile; off.discoveryOn = false; off.linkCount = links.count
        off.prerequisites.link = !links.isEmpty
        let model = OnboardingModel(profile: off, interests: interests, actions: profileActions(off),
            onExit: {}, onFinish: { _ in }, onBluetoothRecovery: {}, linkActions: linkActions(links),
            onDiscoverySettings: {})
        model.edit(.link)
        return model
    }

    static func settings() -> SettingsModel {
        SettingsModel(profile: profile, actions: profileActions(profile), interests: interests,
                      bluetooth: .available, onboardingExplanationCompleted: true, allowsDiscoveryActivation: true)
    }

    static var settingsNavigation: SettingsNavigationActions {
        .init(back: {}, editProfile: {}, discovery: {}, visibility: {}, links: {})
    }

    static func linkActions(_ owned: [OwnLinkState]) -> LinkActions {
        LinkActions(loadLinks: { owned }, loadConnection: { .connected(handle: "aki") },
            connectGitHub: { .connected(handle: "aki") }, listRepositories: { _ in
                .init(repositories: links.prefix(2).map {
                    .init(repositoryID: $0.sourceItemID!, repositoryName: $0.repositoryName,
                          title: $0.title, description: $0.description, mainLanguage: $0.mainLanguage,
                          tags: $0.tags, url: $0.url)
                })
            }, previewRepository: { repository in
                .init(repositoryID: repository.repositoryID, repositoryName: repository.repositoryName,
                      source: .github, url: repository.url, verified: true, sourceLabel: "GitHub",
                      title: repository.title, description: repository.description,
                      mainLanguage: repository.mainLanguage, tags: repository.tags)
            }, saveRepository: { _, _, _ in links[0] }, updateLink: { _, _, _ in links[0] },
            deleteLink: { id in owned.filter { $0.id != id } }, reorderLinks: { _ in owned },
            refreshPreview: { $0 })
    }

    static func linksModel() -> LinksModel {
        LinksModel(actions: linkActions(links), links: links, discoveryOn: true)
    }

    static func sample() -> SampleEncounterModel {
        SampleEncounterModel(store: GalleryDismissalStore(), isNewUser: true)
    }

    static var discoverNavigation: DiscoverNavigationActions {
        .init(openEncounter: { _ in }, openFavorites: {}, openSession: {}, openQR: {},
              openDiscoverySettings: {}, openProfileEditing: {}, openReportOrBlock: { _ in },
              reportImpersonation: { _, _ in }, openSample: {}, openOwnLinks: {}, openSystemSettings: {},
              openBluetoothRecovery: {}, back: {}, encounterRemoved: {})
    }

    enum FeedState { case cards, loading, error, bluetoothOff, discoveryOff, empty }

    static func discover(_ state: FeedState = .cards) -> DiscoverModel {
        let entries = state == .empty ? [] : cards.map {
            EncounterFeedCard(card: $0, favorite: true, sharedInterestIDs: ["ios", "oss"])
        }
        let list = EncounterCardList(cards: entries, truncated: false)
        let actions = DiscoverActions(loadFeed: {
            if state == .loading {
                // SwiftUI cancels this task when its hosting window is released.
                try await Task.sleep(for: .seconds(3600))
            }
            if state == .error { throw DiscoverActionError.unavailable }
            return list
        }, loadCard: { id in
            cards.first(where: { $0.id == id }).map {
                EncounterDetail(card: $0, favorite: true, savedLinkIDs: ["ren-tool"])
            }
        }, setFavorite: { id, favorite in .init(encounterID: id, favorite: favorite) },
           saveLink: { id, link in .init(encounterID: id, linkID: link, saved: true) },
           unsaveLink: { id, link in .init(encounterID: id, linkID: link, saved: false) },
           deleteEncounter: { _ in }, loadFavorites: { list }, loadSavedLinks: {
               .init(links: state == .empty ? [] : encounterLinks.map {
                   .init(encounterID: cards[0].id, day: day, kind: .ambient, link: $0)
               }, truncated: false)
           })
        return DiscoverModel(actions: actions, discoveryOn: state != .discoveryOff)
    }

    static func feed(_ state: FeedState) -> GalleryContent {
        GalleryContent(DiscoverFeedView(model: discover(state), sample: sample(), navigation: discoverNavigation,
            interests: [interests[0], interests[5]], sessionActive: false,
            bluetooth: state == .bluetoothOff ? .poweredOff : .available, prerequisites: profile.prerequisites,
            retryOwnState: {}, retryBluetooth: {}))
    }

    static func favorites(empty: Bool) -> GalleryContent {
        GalleryContent(DiscoverFavoritesView(model: discover(empty ? .empty : .cards), sample: sample(),
            navigation: discoverNavigation, prerequisites: profile.prerequisites, retryOwnState: {}))
    }

    static var sessionNavigation: SessionNavigationActions {
        .init(openQR: {}, openEncounter: { _ in }, close: {}, openDiscoveryOff: {})
    }

    static func session(ended: Bool) -> GalleryContent {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let acknowledgement = SessionAcknowledgement(sessionID: "gallery-session", startsAt: now,
                                                     expiresAt: now.addingTimeInterval(7200), serverTime: now)
        let model = SessionModel(state: .active(acknowledgement), actions: .init(
            startSession: { acknowledgement }, stopSession: {},
            refreshSession: { ended ? .none : .active(acknowledgement) }),
            navigation: sessionNavigation, monotonicNow: { 0 })
        if ended { model.stopLocally() }
        return GalleryContent(SessionView(model: model, navigation: sessionNavigation))
    }

    static func qr(scan: Bool) -> GalleryContent {
        let navigation = QRNavigationActions(openEncounter: { _ in }, openIOSSettings: {},
                                             close: {}, openDiscoveryOff: {})
        let code = QRCode(payload: QRPayload(token: String(repeating: "a", count: 32))!,
                          expiresAt: Date(timeIntervalSince1970: 1_792_000_120))
        let model = QRModel(actions: .init(issueCode: { code }, cancelCode: { _ in },
                                          redeemCode: { _ in cards[0].id }),
                            navigation: navigation, monotonicNow: { 0 })
        if scan { model.select(.scan) }
        // An inactive scene prevents QRView from constructing a live scanner even if the
        // test host already has camera permission. No permission request is ever invoked.
        return GalleryContent(QRView(model: model, navigation: navigation).environment(\.scenePhase, .inactive)) {
            // QRView's task reads the host's permission; replace it with a fixed scan prompt.
            model.receiveCameraPermission(.notDetermined)
        }
    }

    static func dailyReport() -> GalleryContent {
        let data = ReportSettingsData(time: .init(hour: 21, minute: 0), timeZone: "Asia/Tokyo")
        let model = ReportSettingsModel(pushAvailable: false, actions: .init(load: { data },
            saveTime: { time in var result = data; result.time = time; return result },
            setNotifications: { enabled in var result = data; result.notificationsEnabled = enabled; return result },
            requestPermission: { .allowed }), navigation: .init(back: {}, systemSettings: {}))
        return GalleryContent(ReportSettingsView(model: model))
    }

    static func blocked(empty: Bool) -> GalleryContent {
        let list = SafetyBlockList(blocks: empty ? [] : [.init(id: "block-0001", placedDay: day)])
        let model = SafetyBlockedModel(actions: .init(load: { list }, unblock: { _ in }),
                                       navigation: .init(back: {}))
        return GalleryContent(SafetyBlockedUsersView(model: model))
    }

    static func account() -> GalleryContent {
        let data = AccountSettingsData(githubConnected: true, githubHandle: "aki", discoveryOn: true,
                                       linkCount: 3, githubRepositoryCount: 2)
        let model = AccountSettingsModel(actions: .init(load: { data }, disconnectGitHub: {
            var result = data; result.githubConnected = false; result.githubHandle = nil; return result
        }, signOut: {}, deleteAccount: { true }, reloadAccount: { .present(data) },
           resumeParticipation: {}, suspendParticipation: {}),
           navigation: .init(back: {}, signedOut: {}, discovery: {}, support: {}))
        return GalleryContent(AccountSettingsView(model: model))
    }

    static func report(accepted: Bool) async -> GalleryContent {
        let model = SafetyReportModel(encounterID: cards[0].id,
            actions: .init(report: { _ in }, block: { _ in }, conceal: {}, clearPendingHide: {},
                           authorizeReopening: { true }),
            navigation: .init(completed: {}, reopenEncounter: {}))
        if accepted { model.reason = .spam; await model.submit() }
        return GalleryContent(SafetyReportSheet(model: model))
    }
}
