import SwiftUI
import UIKit

// Resolve the wrapper explicitly; the SDK's State macro requires a compiler plugin.
typealias DiscoverViewState<Value> = State<Value>

/// S06. The caller owns the tab bar, navigation stack, radio status and own-profile state.
@MainActor
public struct DiscoverFeedView: View {
    @ObservedObject private var model: DiscoverModel
    @ObservedObject private var sample: SampleEncounterModel
    @Environment(\.scenePhase) private var scenePhase
    private let navigation: DiscoverNavigationActions
    private let interests: [InterestOption]
    private let sessionActive: Bool
    private let bluetooth: DiscoverBluetoothStatus
    private let prerequisites: ProfilePrerequisites
    private let ownState: DiscoverLoadState
    private let retryOwnState: @MainActor () async -> Void
    private let retryBluetooth: @MainActor () async -> Void

    public init(model: DiscoverModel, sample: SampleEncounterModel, navigation: DiscoverNavigationActions,
                interests: [InterestOption], sessionActive: Bool,
                bluetooth: DiscoverBluetoothStatus, prerequisites: ProfilePrerequisites = .init(),
                ownState: DiscoverLoadState = .loaded,
                retryOwnState: @escaping @MainActor () async -> Void,
                retryBluetooth: @escaping @MainActor () async -> Void) {
        self.model = model; self.sample = sample; self.navigation = navigation
        self.interests = interests; self.sessionActive = sessionActive; self.bluetooth = bluetooth
        self.prerequisites = prerequisites; self.ownState = ownState
        self.retryOwnState = retryOwnState; self.retryBluetooth = retryBluetooth
    }

    public var body: some View {
        DiscoverPage(title: .discover) {
            Text(DiscoverStrings.text(.feedSubtitle)).foregroundStyle(.secondary)
            if DiscoverFeedContent.select(discoveryOn: model.discoveryOn, isAuthorized: model.isAuthorized,
                                          state: model.feedState, hasCards: !model.feed.isEmpty) == .discoveryOff {
                DiscoverDiscoveryOffPanel(sample: sample, prerequisites: prerequisites, state: ownState,
                                          navigation: navigation, retry: retryOwnState)
            } else {
                Button(DiscoverStrings.text(.discoveryEnabled), action: navigation.openDiscoverySettings)
                Text(DiscoverStrings.text(.background)).font(.caption).foregroundStyle(.secondary)
                DiscoverSessionControls(sessionActive: sessionActive, bluetooth: bluetooth, navigation: navigation)
                if !interests.isEmpty {
                    DiscoverHeading(key: .yourInterests)
                    DiscoverInterestChips(interests: interests, action: navigation.openProfileEditing)
                }
                DiscoverAdaptiveActions {
                    ForEach(DiscoverFeedShortcut.allCases, id: \.self) { shortcut in
                        Button(DiscoverStrings.text(shortcut.label)) { shortcut.open(using: navigation) }
                            .buttonStyle(.bordered)
                    }
                }
                if bluetooth != .available {
                    DiscoverBluetoothUnavailablePanel(status: bluetooth, discoveryOn: true,
                                                       navigation: navigation, retry: retryBluetooth)
                }
                switch DiscoverFeedContent.select(discoveryOn: model.discoveryOn, isAuthorized: model.isAuthorized,
                                                  state: model.feedState, hasCards: !model.feed.isEmpty) {
                case .discoveryOff: EmptyView()
                case .loading: DiscoverSkeleton()
                case .failure:
                    DiscoverFailure { await model.loadFeed() }
                    SampleEncounterTile(model: sample, context: .emptyFeed, navigation: navigation)
                case .empty:
                    DiscoverEmptyFeedPanel(sample: sample, sessionActive: sessionActive,
                                           bluetooth: bluetooth, navigation: navigation)
                case .cards:
                    DiscoverDayGroups(groups: model.dayGroups, navigation: navigation)
                }
                if model.feedTruncated { Text(DiscoverStrings.text(.truncated)).foregroundStyle(.secondary) }
                Text(DiscoverStrings.text(.pace)).font(.callout).foregroundStyle(.secondary)
            }
        }
        .task { await model.loadFeed() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.loadFeed() } }
        }
    }
}

/// S07 for a real encounter. Opening and foregrounding always re-authorize the card.
@MainActor
public struct EncounterDetailView: View {
    @ObservedObject private var model: DiscoverModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    private let encounterID: String
    private let viewerPurposes: Set<ProfilePurpose>
    private let viewerInterestIDs: Set<String>
    private let navigation: DiscoverNavigationActions

    public init(encounterID: String, model: DiscoverModel, viewerPurposes: Set<ProfilePurpose>,
                viewerInterestIDs: Set<String>,
                navigation: DiscoverNavigationActions) {
        self.encounterID = encounterID; self.model = model
        self.viewerPurposes = viewerPurposes; self.viewerInterestIDs = viewerInterestIDs; self.navigation = navigation
    }

    public var body: some View {
        DiscoverPage(title: .encounter) {
            Text(DiscoverStrings.text(.authorizedOnly)).font(.callout).foregroundStyle(.secondary)
            if !model.discoveryOn {
                DiscoverSurface {
                    DiscoverHeading(key: .discoveryOff)
                    Text(DiscoverStrings.text(.notParticipating))
                    Button(DiscoverStrings.text(.enableDiscovery), action: navigation.openDiscoverySettings)
                }
            } else if !model.isAuthorized {
                DiscoverFailure { await model.loadCard(encounterID) }
            } else {
                switch model.detailState {
                case .idle, .loading: DiscoverSkeleton()
                case .failed: DiscoverFailure { await model.loadCard(encounterID) }
                case .missing: EmptyView()
                case .loaded:
                    if let detail = model.card, detail.card.id == encounterID {
                        let card = detail.card
                        DiscoverSurface {
                            EncounterIdentity(displayName: card.displayName)
                            if let introduction = card.introduction { Text(introduction) }
                            Text(card.day.formatted(locale: locale))
                            Text(DiscoverStrings.text(card.kind.discoverLabel)).font(.callout).foregroundStyle(.secondary)
                            if card.isShell { Text(DiscoverStrings.text(.shell)) }
                            EncounterProfileSections(interests: card.interests, purposes: card.purposes,
                                                     sharedInterests: card.interests.filter { viewerInterestIDs.contains($0.id) },
                                                     sharedPurposes: card.purposes.intersection(viewerPurposes))
                        }
                        if card.links.isEmpty { Text(DiscoverStrings.text(.noLinks)).foregroundStyle(.secondary) }
                        ForEach(card.links) { link in
                            EncounterLinkView(link: link, isSample: false, saved: detail.savedLinkIDs.contains(link.id),
                                              disabled: model.isWriting, reportImpersonation: {
                                EncounterDetailControls.report(card: card, linkID: link.id, navigation: navigation)
                            }) {
                                Task { await model.setSaved(card.id, linkID: link.id,
                                                           saved: !detail.savedLinkIDs.contains(link.id)) }
                            }
                        }
                        if let contact = card.contactDetail {
                            DiscoverSurface { DiscoverHeading(key: .contact); Text(contact) }
                        }
                        DiscoverWriteFailure(model: model)
                        Button(DiscoverStrings.text(.safety)) { navigation.openReportOrBlock(card) }
                            .disabled(model.isWriting)
                        Button(DiscoverStrings.text(.deleteEncounter), role: .destructive) {
                            model.requestDeletion(card.id)
                        }.disabled(model.isWriting)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button(DiscoverStrings.text(.back), action: navigation.back) }
            ToolbarItem(placement: .topBarTrailing) {
                if model.canRead, model.detailState == .loaded, let detail = model.card, detail.card.id == encounterID {
                    Button {
                        Task { await model.setFavorite(detail.card.id, favorite: !detail.favorite) }
                    } label: {
                        Label(DiscoverStrings.text(EncounterDetailControls(detail: detail).favoriteLabel),
                              systemImage: detail.favorite ? "star.fill" : "star")
                    }.disabled(model.isWriting)
                }
            }
        }
        .confirmationDialog(DiscoverStrings.text(.deleteEncounter), isPresented: Binding(
            get: { if case .confirming = model.deletion { return true }; return false },
            set: { if !$0 { model.cancelDeletion() } }
        ), titleVisibility: .visible) {
            Button(DiscoverStrings.text(.deleteEncounter), role: .destructive) {
                model.approveDeletion()
                Task { await model.confirmDeletion() }
            }
            Button(DiscoverStrings.text(.cancel), role: .cancel) { model.cancelDeletion() }
        } message: {
            Text(DiscoverStrings.text(.deleteExplanation))
        }
        .task(id: encounterID) { await model.loadCard(encounterID) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.loadCard(encounterID) } }
        }
        .onChange(of: model.detailState) { _, state in
            if state == .missing { navigation.encounterRemoved() }
        }
    }
}

/// S07 sample context. No load, date, kind, contact, mutation or safety controls exist here.
@MainActor
public struct SampleEncounterDetailView: View {
    @ObservedObject private var sample: SampleEncounterModel
    @Environment(\.locale) private var locale
    private let navigation: DiscoverNavigationActions

    public init(sample: SampleEncounterModel, navigation: DiscoverNavigationActions) {
        self.sample = sample; self.navigation = navigation
    }

    public var body: some View {
        DiscoverPage(title: .sampleEncounter) {
            if sample.isVisible(in: .emptyFeed) {
                let fixture = SampleEncounterPresentation.fixture(language: locale.identifier)
                DiscoverSurface {
                    DiscoverHeading(key: .sampleEncounter)
                    Text(DiscoverStrings.text(.fictional)).foregroundStyle(.secondary)
                    EncounterIdentity(displayName: fixture.displayName)
                    Text(fixture.introduction)
                    EncounterProfileSections(interests: fixture.interests, purposes: fixture.purposes,
                                             sharedInterests: [], sharedPurposes: [])
                }
                ForEach(fixture.links) { link in
                    EncounterLinkView(link: link, isSample: true, saved: false, disabled: false, toggleSaved: {})
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button(DiscoverStrings.text(.back), action: navigation.back) }
        }
    }
}

/// S10. Encounter favorites and saved references load independently.
@MainActor
public struct DiscoverFavoritesView: View {
    @ObservedObject private var model: DiscoverModel
    @ObservedObject private var sample: SampleEncounterModel
    @Environment(\.scenePhase) private var scenePhase
    @DiscoverViewState private var segment: DiscoverFavoritesSegment = .encounters
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let navigation: DiscoverNavigationActions
    private let prerequisites: ProfilePrerequisites
    private let ownState: DiscoverLoadState
    private let retryOwnState: @MainActor () async -> Void

    public init(model: DiscoverModel, sample: SampleEncounterModel, navigation: DiscoverNavigationActions,
                prerequisites: ProfilePrerequisites = .init(), ownState: DiscoverLoadState = .loaded,
                retryOwnState: @escaping @MainActor () async -> Void) {
        self.model = model; self.sample = sample; self.navigation = navigation
        self.prerequisites = prerequisites; self.ownState = ownState; self.retryOwnState = retryOwnState
    }

    public var body: some View {
        DiscoverPage(title: .favorites) {
            if !model.discoveryOn {
                DiscoverDiscoveryOffPanel(sample: sample, prerequisites: prerequisites, state: ownState,
                                          navigation: navigation, retry: retryOwnState)
            } else {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        Button(DiscoverStrings.text(.encounters)) { segment = .encounters }
                            .accessibilityAddTraits(segment == .encounters ? .isSelected : [])
                        Button(DiscoverStrings.text(.savedLinks)) { segment = .savedLinks }
                            .accessibilityAddTraits(segment == .savedLinks ? .isSelected : [])
                    }
                } else {
                    Picker(DiscoverStrings.text(.favorites), selection: $segment) {
                        Text(DiscoverStrings.text(.encounters)).tag(DiscoverFavoritesSegment.encounters)
                        Text(DiscoverStrings.text(.savedLinks)).tag(DiscoverFavoritesSegment.savedLinks)
                    }.pickerStyle(.segmented)
                }
                switch !model.isAuthorized ? .failed : (segment == .encounters ? model.favoritesState : model.savedLinksState) {
                case .idle, .loading: DiscoverSkeleton()
                case .failed, .missing: DiscoverFailure { await loadSelectedSegment() }
                case .loaded:
                    if segment == .encounters {
                        if model.favorites.isEmpty { empty(.noFavorites) }
                        DiscoverDayGroups(groups: model.favoriteDayGroups, navigation: navigation,
                                          removeFavorite: { id in
                            Task { await model.setFavorite(id, favorite: false) }
                        }, disabled: model.isWriting)
                        if model.favoritesTruncated { Text(DiscoverStrings.text(.truncated)).foregroundStyle(.secondary) }
                    } else {
                        if model.savedLinks.isEmpty { empty(.noSavedLinks) }
                        ForEach(model.savedLinks) { item in
                            EncounterLinkView(link: item.link, isSample: false, saved: true, disabled: model.isWriting,
                                              viewEncounter: { navigation.openEncounter(item.encounterID) }) {
                                Task { await model.setSaved(item.encounterID, linkID: item.link.id, saved: false) }
                            }
                        }
                        if model.savedLinksTruncated { Text(DiscoverStrings.text(.truncated)).foregroundStyle(.secondary) }
                    }
                    DiscoverWriteFailure(model: model)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button(DiscoverStrings.text(.back), action: navigation.back) }
        }
        .task(id: segment) { await loadSelectedSegment() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await loadSelectedSegment() } }
        }
    }

    private func loadSelectedSegment() async {
        if segment == .encounters { await model.loadFavorites() }
        else { await model.loadSavedLinks() }
    }

    private func empty(_ key: DiscoverString) -> some View {
        DiscoverSurface {
            DiscoverHeading(key: key)
            Text(DiscoverStrings.text(.favoritesGuidance)).foregroundStyle(.secondary)
        }
    }
}

/// S23. Recovery checks are injected and must not repeatedly request denied permission.
@MainActor
public struct DiscoverBluetoothUnavailablePanel: View {
    private let status: DiscoverBluetoothStatus
    private let discoveryOn: Bool
    private let navigation: DiscoverNavigationActions
    private let retry: @MainActor () async -> Void
    @Environment(\.scenePhase) private var scenePhase

    public init(status: DiscoverBluetoothStatus, discoveryOn: Bool,
                navigation: DiscoverNavigationActions, retry: @escaping @MainActor () async -> Void) {
        self.status = status; self.discoveryOn = discoveryOn; self.navigation = navigation; self.retry = retry
    }

    public var body: some View {
        if DiscoverBluetoothContent.select(status) != .hidden {
            DiscoverSurface {
                if case .unavailable = DiscoverBluetoothContent.select(status) {
                    DiscoverHeading(key: .bluetoothUnavailable)
                }
                switch status {
                case .poweredOff: Text(DiscoverStrings.text(.bluetoothOff))
                case .denied: Text(DiscoverStrings.text(.bluetoothDenied))
                case .checking: DiscoverSkeleton()
                case .failed: Text(DiscoverStrings.text(.loadError)).foregroundStyle(.red)
                case .unavailable, .available: EmptyView()
                }
                Button(DiscoverStrings.text(.systemSettings), action: navigation.openSystemSettings)
                Button(DiscoverStrings.text(status == .failed ? .retry : .tryAgain)) { Task { await retry() } }
                    .disabled(status == .checking)
                if discoveryOn { Button(DiscoverStrings.text(.qrExchange), action: navigation.openQR) }
                Button(DiscoverStrings.text(.discoverySettings), action: navigation.openDiscoverySettings)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await retry() } }
            }
        }
    }
}

/// S24. Only the caller's own prerequisites and the fictional sample may appear while off.
@MainActor
public struct DiscoverDiscoveryOffPanel: View {
    @ObservedObject private var sample: SampleEncounterModel
    private let prerequisites: ProfilePrerequisites
    private let state: DiscoverLoadState
    private let navigation: DiscoverNavigationActions
    private let retry: @MainActor () async -> Void

    public init(sample: SampleEncounterModel, prerequisites: ProfilePrerequisites,
                state: DiscoverLoadState = .loaded, navigation: DiscoverNavigationActions,
                retry: @escaping @MainActor () async -> Void) {
        self.sample = sample; self.prerequisites = prerequisites
        self.state = state; self.navigation = navigation; self.retry = retry
    }

    public var body: some View {
        DiscoverSurface {
            DiscoverHeading(key: .discoveryOff)
            Text(DiscoverStrings.text(.notParticipating))
            switch DiscoverPrerequisiteContent.select(state: state, prerequisites: prerequisites) {
            case .loading: DiscoverSkeleton()
            case .failure: DiscoverFailure(retry: retry)
            case let .guidance(editProfile, editLinks):
                Button(DiscoverStrings.text(.enableDiscovery), action: navigation.openDiscoverySettings)
                if editProfile {
                    Button(DiscoverStrings.text(.editProfile), action: navigation.openProfileEditing)
                }
                if editLinks { Button(DiscoverStrings.text(.ownLinks), action: navigation.openOwnLinks) }
            }
            Text(DiscoverStrings.text(.canEdit)).foregroundStyle(.secondary)
        }
        SampleEncounterTile(model: sample, context: .discoveryOff, navigation: navigation)
    }
}

/// S25. Use only after a successful empty feed response, never while loading real cards.
@MainActor
public struct DiscoverEmptyFeedPanel: View {
    @ObservedObject private var sample: SampleEncounterModel
    private let sessionActive: Bool
    private let bluetooth: DiscoverBluetoothStatus
    private let navigation: DiscoverNavigationActions

    public init(sample: SampleEncounterModel, sessionActive: Bool, bluetooth: DiscoverBluetoothStatus,
                navigation: DiscoverNavigationActions) {
        self.sample = sample; self.sessionActive = sessionActive; self.bluetooth = bluetooth
        self.navigation = navigation
    }

    public var body: some View {
        DiscoverSurface {
            DiscoverHeading(key: .emptyFeed)
            Text(DiscoverStrings.text(.dailyReport)).foregroundStyle(.secondary)
        }
        SampleEncounterTile(model: sample, context: .emptyFeed, navigation: navigation)
        DiscoverSessionControls(sessionActive: sessionActive, bluetooth: bluetooth, navigation: navigation)
    }
}

@MainActor
struct DiscoverPage<Content: View>: View {
    let title: DiscoverString
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle(DiscoverStrings.text(title))
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(.teal)
    }
}

@MainActor
struct DiscoverSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

@MainActor
struct DiscoverHeading: View {
    let key: DiscoverString
    var body: some View {
        Text(DiscoverStrings.text(key)).font(.headline).accessibilityAddTraits(.isHeader)
    }
}

@MainActor
struct DiscoverAdaptiveActions<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: () -> Content
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12, content: content)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20, content: content)
                VStack(alignment: .leading, spacing: 12, content: content)
            }
        }
    }
}

@MainActor
struct DiscoverSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(DiscoverStrings.text(.loading))
            ForEach(0..<3) { _ in
                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)).frame(height: 44)
                    .accessibilityHidden(true)
            }
        }.accessibilityElement(children: .combine).accessibilityLabel(DiscoverStrings.text(.loading))
    }
}

@MainActor
struct DiscoverFailure: View {
    let retry: @MainActor () async -> Void
    var body: some View {
        DiscoverSurface {
            Text(DiscoverStrings.text(.loadError)).foregroundStyle(.red)
            Button(DiscoverStrings.text(.retry)) { Task { await retry() } }
        }
    }
}

@MainActor
struct DiscoverWriteFailure: View {
    @ObservedObject var model: DiscoverModel
    var body: some View {
        if model.isWriting { ProgressView(DiscoverStrings.text(.loading)) }
        if model.failedOperation != nil {
            Text(DiscoverStrings.text(.writeError)).foregroundStyle(.red)
            Button(DiscoverStrings.text(.retry)) { Task { await model.retryOperation() } }.disabled(model.isWriting)
        }
    }
}

@MainActor
struct DiscoverSessionControls: View {
    let sessionActive: Bool
    let bluetooth: DiscoverBluetoothStatus
    let navigation: DiscoverNavigationActions
    var body: some View {
        DiscoverAdaptiveActions {
            Button(DiscoverStrings.text(sessionActive ? .viewSession : .startSession)) {
                DiscoverSessionDestination.select(sessionActive: sessionActive, bluetooth: bluetooth).open(using: navigation)
            }.buttonStyle(.borderedProminent)
            Button(DiscoverStrings.text(.qrExchange), action: navigation.openQR).buttonStyle(.bordered)
        }
    }
}

@MainActor
struct SampleEncounterTile: View {
    @ObservedObject var model: SampleEncounterModel
    let context: SampleEncounterContext
    let navigation: DiscoverNavigationActions
    var body: some View {
        if model.isVisible(in: context) {
            DiscoverSurface {
                DiscoverHeading(key: .sampleEncounter)
                Text(DiscoverStrings.text(.fictional)).foregroundStyle(.secondary)
                Text(DiscoverStrings.text(.sampleName))
                Text(DiscoverStrings.text(.sampleWork))
                Button(DiscoverStrings.text(.viewSample), action: navigation.openSample)
                Button(DiscoverStrings.text(.dismissSample)) { model.dismiss() }
            }
        }
    }
}

@MainActor
struct DiscoverDayGroups: View {
    let groups: [EncounterDayGroup]
    let navigation: DiscoverNavigationActions
    var removeFavorite: (@MainActor (String) -> Void)?
    var disabled = false
    @Environment(\.locale) private var locale
    var body: some View {
        ForEach(groups) { group in
            Text(group.day.formatted(locale: locale)).font(.title2).accessibilityAddTraits(.isHeader)
            ForEach(group.cards) { entry in
                let card = entry.card
                DiscoverSurface {
                    Button { navigation.openEncounter(card.id) } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            EncounterIdentity(displayName: card.displayName)
                            if card.isShell { Text(DiscoverStrings.text(.shell)) }
                            if !entry.sharedInterests.isEmpty {
                                Text(DiscoverStrings.sharedCount(entry.sharedInterests.count, locale: locale))
                                DiscoverInterestChips(interests: entry.sharedInterests)
                            }
                            Text(DiscoverStrings.text(card.kind.discoverLabel)).foregroundStyle(.secondary)
                            if let link = card.links.first {
                                if !link.title.isEmpty { Text(link.title).font(.headline) }
                                if !link.source.isEmpty { Text(link.source).foregroundStyle(.secondary) }
                                EncounterTextChips(values: link.tags)
                                EncounterVerification(verified: link.verified)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button(DiscoverStrings.text(.viewWork)) { navigation.openEncounter(card.id) }
                    if let removeFavorite {
                        Button(DiscoverStrings.text(.removeFavorite)) { removeFavorite(card.id) }.disabled(disabled)
                    }
                }
            }
        }
    }
}

@MainActor
struct EncounterIdentity: View {
    let displayName: String?
    var body: some View {
        if let displayName {
            HStack(alignment: .top, spacing: 12) {
                Text(String(displayName.prefix(1))).font(.title2).padding(12)
                    .background(Color.teal.opacity(0.15), in: Circle()).accessibilityHidden(true)
                Text(displayName).font(.title2).bold()
            }
        }
    }
}

@MainActor
struct DiscoverInterestChips: View {
    let interests: [InterestOption]
    var action: (@MainActor () -> Void)?
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] :
                  [GridItem(.adaptive(minimum: 140))], alignment: .leading) {
            ForEach(interests) { interest in
                if let action {
                    Button(interest.label(language: locale.identifier), action: action)
                        .buttonStyle(.bordered).frame(minHeight: 44)
                } else {
                    Text(interest.label(language: locale.identifier)).padding(8)
                        .background(Color.teal.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

@MainActor
struct EncounterTextChips: View {
    let values: [String]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        if !values.isEmpty {
            LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] :
                      [GridItem(.adaptive(minimum: 140))], alignment: .leading) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(value).font(.callout).padding(8)
                        .background(Color.teal.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

@MainActor
struct EncounterProfileSections: View {
    let interests: [InterestOption]
    let purposes: Set<ProfilePurpose>
    let sharedInterests: [InterestOption]
    let sharedPurposes: Set<ProfilePurpose>
    var body: some View {
        if !purposes.isEmpty {
            DiscoverHeading(key: .purposes)
            EncounterTextChips(values: purposeLabels(purposes))
        }
        if !interests.isEmpty {
            DiscoverHeading(key: .interests)
            DiscoverInterestChips(interests: interests)
        }
        if !sharedInterests.isEmpty || !sharedPurposes.isEmpty {
            DiscoverHeading(key: .common)
            DiscoverInterestChips(interests: sharedInterests)
            EncounterTextChips(values: purposeLabels(sharedPurposes))
        }
    }

    private func purposeLabels(_ values: Set<ProfilePurpose>) -> [String] {
        ProfilePurpose.allCases.filter { values.contains($0) }.map {
            DiscoverStrings.text($0 == .discovery ? .discoveryPurpose : .collaborationPurpose)
        }
    }
}

@MainActor
struct EncounterVerification: View {
    let verified: Bool
    var body: some View {
        Label(DiscoverStrings.text(verified ? .verified : .unverified),
              systemImage: verified ? "checkmark.seal" : "questionmark.circle")
            .font(.caption).foregroundStyle(.secondary)
    }
}

@MainActor
struct EncounterLinkView: View {
    let link: EncounterLinkCard
    let isSample: Bool
    let saved: Bool
    let disabled: Bool
    var viewEncounter: (@MainActor () -> Void)? = nil
    var reportImpersonation: (@MainActor () -> Void)? = nil
    let toggleSaved: @MainActor () -> Void
    var body: some View {
        DiscoverSurface {
            if !link.source.isEmpty { Text(link.source).font(.callout).foregroundStyle(.secondary) }
            if !link.title.isEmpty { Text(link.title).font(.headline) }
            if let description = link.description { Text(description) }
            EncounterTextChips(values: link.tags)
            if let language = link.mainLanguage { Text(language).font(.callout).foregroundStyle(.secondary) }
            if let opening = link.openingText { Text(opening) }
            EncounterVerification(verified: link.verified)
            if !link.verified { Text(DiscoverStrings.text(.unverifiedExplanation)).font(.caption).foregroundStyle(.secondary) }
            Link(DiscoverStrings.text(.openOriginal), destination: link.url)
            if let viewEncounter { Button(DiscoverStrings.text(.viewEncounter), action: viewEncounter) }
            if !isSample {
                Button(DiscoverStrings.text(saved ? .unsaveLink : .saveLink), action: toggleSaved)
                    .disabled(disabled)
                if let reportImpersonation {
                    Button(DiscoverStrings.text(.reportImpersonation), action: reportImpersonation).disabled(disabled)
                }
            }
        }
    }
}

extension EncounterKind {
    var discoverLabel: DiscoverString {
        switch self { case .ambient: .ambient; case .session: .session; case .qr: .qrKind }
    }
}
