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
            Text(DiscoverStrings.text(.feedSubtitle)).foregroundStyle(EncounterPalette.inkSecondary)
            if DiscoverFeedContent.select(discoveryOn: model.discoveryOn, isAuthorized: model.isAuthorized,
                                          state: model.feedState, hasCards: !model.feed.isEmpty) == .discoveryOff {
                DiscoverDiscoveryOffPanel(sample: sample, prerequisites: prerequisites, state: ownState,
                                          navigation: navigation, retry: retryOwnState)
            } else {
                Button(action: navigation.openDiscoverySettings) {
                    DiscoverStatusCapsule()
                }.buttonStyle(.plain)
                Text(DiscoverStrings.text(.background)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                DiscoverSessionControls(sessionActive: sessionActive, bluetooth: bluetooth, navigation: navigation)
                if !interests.isEmpty {
                    EncounterSectionHeader(DiscoverStrings.text(.yourInterests))
                    DiscoverInterestChips(interests: interests, action: navigation.openProfileEditing)
                }
                DiscoverAdaptiveActions {
                    ForEach(DiscoverFeedShortcut.allCases, id: \.self) { shortcut in
                        Button { shortcut.open(using: navigation) } label: {
                            DiscoverCapsuleLabel(key: shortcut.label, symbol: "star")
                        }.buttonStyle(.plain)
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
                if model.feedTruncated { Text(DiscoverStrings.text(.truncated)).foregroundStyle(EncounterPalette.inkSecondary) }
                if !model.failedCardReloadIDs.isEmpty {
                    DiscoverFailure { await model.retryCardReloads() }
                }
                Text(DiscoverStrings.text(.pace)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
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
            Text(DiscoverStrings.text(.authorizedOnly)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            if !model.discoveryOn {
                DiscoverSurface {
                    DiscoverPanelHeader(key: .discoveryOff, symbol: "pause.circle")
                    Text(DiscoverStrings.text(.notParticipating))
                    Button(DiscoverStrings.text(.enableDiscovery), action: navigation.openDiscoverySettings)
                        .buttonStyle(EncounterButtonStyle(.primary))
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
                        let deferred = EncounterDetailControls.availableDeferredControls(actions: model.actions, navigation: navigation)
                        DiscoverSurface {
                            DiscoverProfileHeader(displayName: card.displayName, introduction: card.introduction)
                            DiscoverAdaptiveRow {
                                HStack(spacing: 8) {
                                    Image(systemName: "calendar").accessibilityHidden(true)
                                    Text(card.day.formatted(locale: locale))
                                }
                                Text(DiscoverStrings.text(card.kind.discoverLabel))
                            }.font(.callout).foregroundStyle(EncounterPalette.inkSecondary)
                            if card.isShell { Text(DiscoverStrings.text(.shell)) }
                        }
                        EncounterProfileSections(interests: card.interests, purposes: card.purposes,
                                                 sharedInterests: card.interests.filter { viewerInterestIDs.contains($0.id) },
                                                 sharedPurposes: card.purposes.intersection(viewerPurposes))
                        if card.links.isEmpty { Text(DiscoverStrings.text(.noLinks)).foregroundStyle(EncounterPalette.inkSecondary) }
                        ForEach(card.links) { link in
                            EncounterLinkView(link: link, isSample: false, saved: detail.savedLinkIDs.contains(link.id),
                                              disabled: model.isWriting, reportImpersonation: deferred.contains(.impersonation) ? navigation.reportImpersonation.map { report in
                                { report(card, link.id) }
                            } : nil) {
                                Task { await model.setSaved(card.id, linkID: link.id,
                                                           saved: !detail.savedLinkIDs.contains(link.id)) }
                            }
                        }
                        if let contact = card.contactDetail {
                            DiscoverSurface { DiscoverPanelHeader(key: .contact, symbol: "envelope"); Text(contact) }
                        }
                        DiscoverWriteFailure(model: model)
                        if deferred.contains(.safety) || deferred.contains(.deletion) {
                            DiscoverDivider()
                            DiscoverDividedActions {
                                if deferred.contains(.safety), let safety = navigation.openReportOrBlock {
                                    Button { safety(card) } label: {
                                        DiscoverActionLabel(key: .safety, symbol: "exclamationmark.triangle")
                                            .font(.subheadline.weight(.semibold))
                                    }.buttonStyle(EncounterButtonStyle(.destructiveText)).disabled(model.isWriting)
                                }
                                if deferred.contains(.safety) && deferred.contains(.deletion) {
                                    DiscoverActionDivider()
                                }
                                if deferred.contains(.deletion) {
                                    Button(role: .destructive) {
                                        model.requestDeletion(card.id)
                                    } label: {
                                        DiscoverActionLabel(key: .deleteEncounter, symbol: "trash")
                                            .font(.subheadline.weight(.semibold))
                                    }.buttonStyle(EncounterButtonStyle(.destructiveText)).disabled(model.isWriting)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EncounterBackButton(label: DiscoverStrings.text(.back), action: navigation.back) }
            ToolbarItem(placement: .topBarTrailing) {
                if model.canRead, model.detailState == .loaded, let detail = model.card, detail.card.id == encounterID {
                    Button {
                        Task { await model.setFavorite(detail.card.id, favorite: !detail.favorite) }
                    } label: {
                        Label(DiscoverStrings.text(EncounterDetailControls(detail: detail).favoriteLabel),
                              systemImage: detail.favorite ? "star.fill" : "star")
                            .labelStyle(.iconOnly).font(.title3)
                            .frame(minWidth: 44, minHeight: 44)
                    }.buttonStyle(EncounterPlainButtonStyle()).foregroundStyle(EncounterPalette.accent).disabled(model.isWriting)
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
                    DiscoverPanelHeader(key: .sampleEncounter, symbol: "sparkles")
                    Text(DiscoverStrings.text(.fictional)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                    DiscoverProfileHeader(displayName: fixture.displayName, introduction: fixture.introduction)
                }
                EncounterProfileSections(interests: fixture.interests, purposes: fixture.purposes,
                                         sharedInterests: [], sharedPurposes: [])
                ForEach(fixture.links) { link in
                    EncounterLinkView(link: link, isSample: true, saved: false, disabled: false, toggleSaved: {})
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EncounterBackButton(label: DiscoverStrings.text(.back), action: navigation.back) }
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
                EncounterSegmentedControl(segments: [
                    .init(DiscoverFavoritesSegment.encounters, label: DiscoverStrings.text(.encounters)),
                    .init(DiscoverFavoritesSegment.savedLinks, label: DiscoverStrings.text(.savedLinks))
                ], selection: $segment, label: DiscoverStrings.text(.favorites))
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
                        if model.favoritesTruncated { Text(DiscoverStrings.text(.truncated)).foregroundStyle(EncounterPalette.inkSecondary) }
                    } else {
                        if model.savedLinks.isEmpty { empty(.noSavedLinks) }
                        ForEach(model.savedLinks) { item in
                            EncounterLinkView(link: item.link, isSample: false, saved: true, disabled: model.isWriting,
                                              viewEncounter: { navigation.openEncounter(item.encounterID) }) {
                                Task { await model.setSaved(item.encounterID, linkID: item.link.id, saved: false) }
                            }
                        }
                        if model.savedLinksTruncated { Text(DiscoverStrings.text(.truncated)).foregroundStyle(EncounterPalette.inkSecondary) }
                    }
                    DiscoverWriteFailure(model: model)
                }
                if !model.failedCardReloadIDs.isEmpty {
                    DiscoverFailure { await model.retryCardReloads() }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EncounterBackButton(label: DiscoverStrings.text(.back), action: navigation.back) }
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
            DiscoverPanelHeader(key: key, symbol: "star")
            Text(DiscoverStrings.text(.favoritesGuidance)).foregroundStyle(EncounterPalette.inkSecondary)
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
                    DiscoverPanelHeader(key: .bluetoothUnavailable, symbol: "antenna.radiowaves.left.and.right.slash")
                }
                switch status {
                case .poweredOff: Text(DiscoverStrings.text(.bluetoothOff))
                case .denied: Text(DiscoverStrings.text(.bluetoothDenied))
                case .checking: DiscoverSkeletonContent()
                case .failed:
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                        Text(DiscoverStrings.text(.loadError))
                    }.foregroundStyle(EncounterPalette.destructive)
                case .unavailable, .available: EmptyView()
                }
                DiscoverAdaptiveActions {
                    Button(DiscoverStrings.text(.systemSettings), action: navigation.openSystemSettings)
                        .buttonStyle(EncounterButtonStyle(.primary))
                    Button(DiscoverStrings.text(status == .failed ? .retry : .tryAgain)) { Task { await retry() } }
                        .buttonStyle(EncounterButtonStyle(.secondary)).disabled(status == .checking)
                }
                if discoveryOn {
                    Button(action: navigation.openQR) {
                        DiscoverActionLabel(key: .qrExchange, symbol: "qrcode")
                    }.buttonStyle(EncounterButtonStyle(.secondary))
                }
                Button(DiscoverStrings.text(.discoverySettings), action: navigation.openDiscoverySettings)
                    .buttonStyle(EncounterButtonStyle(.tertiary))
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
            DiscoverPanelHeader(key: .discoveryOff, symbol: "pause.circle")
            Text(DiscoverStrings.text(.notParticipating))
            switch DiscoverPrerequisiteContent.select(state: state, prerequisites: prerequisites) {
            case .loading: DiscoverSkeletonContent()
            case .failure: DiscoverFailureContent(retry: retry)
            case let .guidance(editProfile, editLinks):
                Button(DiscoverStrings.text(.enableDiscovery), action: navigation.openDiscoverySettings)
                    .buttonStyle(EncounterButtonStyle(.primary))
                if editProfile {
                    Button(DiscoverStrings.text(.editProfile), action: navigation.openProfileEditing)
                        .buttonStyle(EncounterButtonStyle(.secondary))
                }
                if editLinks {
                    Button(DiscoverStrings.text(.ownLinks), action: navigation.openOwnLinks)
                        .buttonStyle(EncounterButtonStyle(.secondary))
                }
            }
            Text(DiscoverStrings.text(.canEdit)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
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
            DiscoverPanelHeader(key: .emptyFeed, symbol: "tray")
            Text(DiscoverStrings.text(.dailyReport)).foregroundStyle(EncounterPalette.inkSecondary)
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
        EncounterScreen(content: content)
            .navigationTitle(DiscoverStrings.text(title))
            .navigationBarTitleDisplayMode(title == .discover ? .large : .inline)
    }
}

@MainActor
struct DiscoverSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { EncounterSurfaceCard(content: content) }
}

@MainActor
struct DiscoverHeading: View {
    let key: DiscoverString
    var body: some View { EncounterSectionHeader(DiscoverStrings.text(key)) }
}

@MainActor
private struct DiscoverPanelHeader: View {
    let key: DiscoverString
    let symbol: String
    var body: some View {
        DiscoverAdaptiveRow {
            EncounterSymbolTile(symbol: symbol)
            DiscoverHeading(key: key)
        }
    }
}

@MainActor
private struct DiscoverActionLabel: View {
    let key: DiscoverString
    let symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(DiscoverStrings.text(key)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
private struct DiscoverCapsuleLabel: View {
    let key: DiscoverString
    let symbol: String
    @ScaledMetric(relativeTo: .body) private var target = 44.0
    @ScaledMetric(relativeTo: .body) private var corner = 16.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        let shape = discoverCapsuleShape(for: dynamicTypeSize, corner: corner)
        DiscoverActionLabel(key: key, symbol: symbol)
            .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 8)
            .frame(minHeight: max(44, target)).foregroundStyle(EncounterPalette.accent)
            .background(EncounterPalette.accentSoft, in: shape)
            .overlay(shape.stroke(EncounterPalette.border, lineWidth: 1))
            .contentShape(shape)
    }
}

@MainActor
private struct DiscoverStatusCapsule: View {
    @ScaledMetric(relativeTo: .body) private var dot = 10.0
    @ScaledMetric(relativeTo: .body) private var target = 44.0
    @ScaledMetric(relativeTo: .body) private var corner = 16.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        let shape = discoverCapsuleShape(for: dynamicTypeSize, corner: corner)
        HStack(spacing: 8) {
            Circle().fill(EncounterPalette.accent).frame(width: dot, height: dot).accessibilityHidden(true)
            Text(DiscoverStrings.text(.discoveryEnabled)).fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.right").accessibilityHidden(true)
        }.font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 8)
            .frame(minHeight: max(44, target)).foregroundStyle(EncounterPalette.accent)
            .background(EncounterPalette.accentSoft, in: shape).contentShape(shape)
    }
}

private func discoverCapsuleShape(for size: DynamicTypeSize, corner: CGFloat) -> AnyShape {
    size.isAccessibilitySize ? AnyShape(RoundedRectangle(cornerRadius: corner, style: .continuous)) : AnyShape(Capsule())
}

@MainActor
private struct DiscoverKindBadge: View {
    let kind: EncounterKind
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var corner = 16.0
    private var foreground: Color {
        switch kind {
        case .ambient: EncounterPalette.ambientText
        case .session: EncounterPalette.sessionText
        case .qr: EncounterPalette.accent
        }
    }
    private var fill: Color {
        switch kind {
        case .ambient: EncounterPalette.ambientFill
        case .session: EncounterPalette.sessionFill
        case .qr: EncounterPalette.accentSoft
        }
    }
    var body: some View {
        Text(DiscoverStrings.text(kind.discoverLabel)).font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background(fill, in: discoverCapsuleShape(for: dynamicTypeSize, corner: corner))
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
    }
}

@MainActor
private struct DiscoverDividedActions<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: () -> Content
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12, content: content)
        } else {
            HStack(spacing: 0, content: content)
        }
    }
}

@MainActor
private struct DiscoverActionDivider: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var height = 28.0
    var body: some View {
        if !dynamicTypeSize.isAccessibilitySize {
            Rectangle().fill(EncounterPalette.border).frame(width: 1, height: height).accessibilityHidden(true)
        }
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
                HStack(spacing: 12, content: content)
                VStack(alignment: .leading, spacing: 12, content: content)
            }
        }
    }
}

@MainActor
private struct DiscoverAdaptiveRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: () -> Content
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ?
            AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) :
            AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout { content() }
    }
}

@MainActor
private struct DiscoverDivider: View {
    var body: some View {
        Rectangle().fill(EncounterPalette.border).frame(height: 1).accessibilityHidden(true)
    }
}

@MainActor
struct DiscoverSkeleton: View {
    var body: some View { DiscoverSurface { DiscoverSkeletonContent() } }
}

@MainActor
private struct DiscoverSkeletonContent: View {
    @ScaledMetric(relativeTo: .body) private var avatar = 56.0
    @ScaledMetric(relativeTo: .body) private var line = 14.0
    @ScaledMetric(relativeTo: .body) private var preview = 64.0
    @ScaledMetric(relativeTo: .body) private var corner = 12.0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DiscoverAdaptiveRow {
                EncounterSymbolTile(symbol: "hourglass")
                EncounterProgress(DiscoverStrings.text(.loading))
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Circle().fill(EncounterPalette.neutralFill).frame(width: min(avatar, 64), height: min(avatar, 64))
                    VStack(alignment: .leading, spacing: 12) {
                        RoundedRectangle(cornerRadius: corner).fill(EncounterPalette.neutralFill)
                            .frame(height: line)
                        RoundedRectangle(cornerRadius: corner).fill(EncounterPalette.neutralFill)
                            .frame(height: line).padding(.trailing, min(avatar, 64))
                    }
                }
                RoundedRectangle(cornerRadius: corner).fill(EncounterPalette.neutralFill).frame(height: preview)
                DiscoverDivider()
                RoundedRectangle(cornerRadius: corner).fill(EncounterPalette.neutralFill).frame(height: line)
            }.accessibilityHidden(true)
        }.accessibilityElement(children: .combine).accessibilityLabel(DiscoverStrings.text(.loading))
    }
}

@MainActor
struct DiscoverFailure: View {
    let retry: @MainActor () async -> Void
    var body: some View { DiscoverSurface { DiscoverFailureContent(retry: retry) } }
}

@MainActor
private struct DiscoverFailureContent: View {
    let retry: @MainActor () async -> Void
    var body: some View {
        EncounterInlineError(message: DiscoverStrings.text(.loadError), retryLabel: DiscoverStrings.text(.retry)) {
            Task { await retry() }
        }
    }
}

@MainActor
struct DiscoverWriteFailure: View {
    @ObservedObject var model: DiscoverModel
    var body: some View {
        if model.isWriting { EncounterProgress(DiscoverStrings.text(.loading)) }
        if model.failedOperation != nil {
            DiscoverSurface {
                EncounterInlineError(message: DiscoverStrings.text(.writeError), retryLabel: DiscoverStrings.text(.retry),
                                     disabled: model.isWriting) {
                    Task { await model.retryOperation() }
                }
            }
        }
    }
}

@MainActor
struct DiscoverSessionControls: View {
    let sessionActive: Bool
    let bluetooth: DiscoverBluetoothStatus
    let navigation: DiscoverNavigationActions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedControls
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    sessionButton(singleLine: true)
                    qrButton(fullWidth: false, singleLine: true)
                }
                stackedControls
            }
        }
    }

    private var stackedControls: some View {
        VStack(spacing: 12) {
            sessionButton()
            qrButton()
        }
    }

    private func sessionButton(singleLine: Bool = false) -> some View {
        Button {
            DiscoverSessionDestination.select(sessionActive: sessionActive, bluetooth: bluetooth).open(using: navigation)
        } label: {
            DiscoverActionLabel(key: sessionActive ? .viewSession : .startSession,
                                symbol: "dot.radiowaves.left.and.right")
                .fixedSize(horizontal: singleLine, vertical: true)
        }.buttonStyle(EncounterButtonStyle(.primary))
    }

    private func qrButton(fullWidth: Bool = true, singleLine: Bool = false) -> some View {
        Button(action: navigation.openQR) {
            DiscoverActionLabel(key: .qrExchange, symbol: "qrcode")
                .fixedSize(horizontal: singleLine, vertical: true)
        }.buttonStyle(EncounterButtonStyle(.secondary, fullWidth: fullWidth))
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
                DiscoverPanelHeader(key: .sampleEncounter, symbol: "sparkles")
                Text(DiscoverStrings.text(.fictional)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                Text(DiscoverStrings.text(.sampleName)).font(.title3.bold())
                Text(DiscoverStrings.text(.sampleWork))
                DiscoverAdaptiveActions {
                    Button(DiscoverStrings.text(.viewSample), action: navigation.openSample)
                        .buttonStyle(EncounterButtonStyle(.secondary))
                    Button(DiscoverStrings.text(.dismissSample)) { model.dismiss() }
                        .buttonStyle(EncounterButtonStyle(.tertiary))
                }
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
            Text(group.day.formatted(locale: locale)).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            ForEach(group.cards) { entry in
                let card = entry.card
                DiscoverSurface {
                    Button { navigation.openEncounter(card.id) } label: {
                        VStack(alignment: .leading, spacing: 16) {
                            DiscoverAdaptiveRow {
                                EncounterIdentity(displayName: card.displayName,
                                                  subtitle: entry.sharedInterests.isEmpty ? nil :
                                                    DiscoverStrings.sharedCount(entry.sharedInterests.count, locale: locale))
                                    .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                                DiscoverKindBadge(kind: card.kind)
                            }
                            if card.isShell { Text(DiscoverStrings.text(.shell)) }
                            if !entry.sharedInterests.isEmpty {
                                DiscoverInterestChips(interests: entry.sharedInterests)
                            }
                            if let link = card.links.first {
                                DiscoverAdaptiveRow {
                                    EncounterSymbolTile(symbol: link.discoverSymbol)
                                    VStack(alignment: .leading, spacing: 8) {
                                        if !link.title.isEmpty { Text(link.title).font(.headline) }
                                        if !link.source.isEmpty {
                                            Text(link.source).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                                        }
                                        EncounterTextChips(values: link.tags)
                                        EncounterVerification(verified: link.verified)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    DiscoverDivider()
                    Button { navigation.openEncounter(card.id) } label: {
                        HStack(spacing: 12) {
                            Text(DiscoverStrings.text(.viewWork)).frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }
                    }.buttonStyle(EncounterButtonStyle(.tertiary))
                    if let removeFavorite {
                        Button(DiscoverStrings.text(.removeFavorite)) { removeFavorite(card.id) }
                            .buttonStyle(EncounterButtonStyle(.tertiary)).disabled(disabled)
                    }
                }
            }
        }
    }
}

@MainActor
struct EncounterIdentity: View {
    let displayName: String?
    private let subtitle: String?

    init(displayName: String?) { self.displayName = displayName; subtitle = nil }
    init(displayName: String?, subtitle: String?) { self.displayName = displayName; self.subtitle = subtitle }

    var body: some View {
        if displayName != nil || subtitle != nil {
            DiscoverAdaptiveRow {
                if let displayName { EncounterAvatar(displayName: displayName, decorative: true) }
                VStack(alignment: .leading, spacing: 4) {
                    if let displayName { Text(displayName).font(.title2.bold()) }
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.layoutPriority(1)
            }
        }
    }
}

@MainActor
private struct DiscoverProfileHeader: View {
    let displayName: String?
    let introduction: String?
    var body: some View {
        if displayName != nil || introduction != nil {
            DiscoverAdaptiveRow {
                if let displayName { EncounterAvatar(displayName: displayName, size: 80, decorative: true) }
                VStack(alignment: .leading, spacing: 12) {
                    if let displayName { Text(displayName).font(.title2.bold()) }
                    if let introduction { Text(introduction).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
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
        if let action {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(interests) { interest in
                        EncounterChip(label: interest.label(language: locale.identifier), selected: false, action: action)
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(interests) { interest in
                            EncounterChip(label: interest.label(language: locale.identifier), selected: false, action: action)
                        }
                    }
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .padding(.horizontal, -20)
                .scrollIndicators(.hidden)
            }
        } else {
            DiscoverInterestTags(interests: interests, tone: .accent)
        }
    }
}

@MainActor
private struct DiscoverInterestTags: View {
    let interests: [InterestOption]
    let tone: EncounterChip.TagTone
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        EncounterFlowLayout(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
            ForEach(interests) { interest in
                EncounterChip(label: interest.label(language: locale.identifier), tone: tone)
            }
        }
    }
}

@MainActor
struct EncounterTextChips: View {
    let values: [String]
    var body: some View { DiscoverTextTags(values: values, tone: .neutral) }
}

@MainActor
private struct DiscoverTextTags: View {
    let values: [String]
    let tone: EncounterChip.TagTone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        if !values.isEmpty {
            EncounterFlowLayout(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    EncounterChip(label: value, tone: tone)
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
            DiscoverSurface {
                DiscoverHeading(key: .purposes)
                EncounterTextChips(values: purposeLabels(purposes))
            }
        }
        if !interests.isEmpty {
            DiscoverSurface {
                DiscoverHeading(key: .interests)
                DiscoverInterestTags(interests: interests, tone: .neutral)
            }
        }
        if !sharedInterests.isEmpty || !sharedPurposes.isEmpty {
            DiscoverSurface {
                DiscoverHeading(key: .common)
                DiscoverInterestChips(interests: sharedInterests)
                DiscoverTextTags(values: purposeLabels(sharedPurposes), tone: .accent)
            }
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
        EncounterBadge(DiscoverStrings.text(verified ? .verified : .unverified),
                       style: verified ? .verified : .unverified,
                       symbol: verified ? "checkmark.seal" : "questionmark.circle")
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
            DiscoverAdaptiveRow {
                EncounterSymbolTile(symbol: link.discoverSymbol)
                if !link.source.isEmpty {
                    Text(link.source).font(.callout).foregroundStyle(EncounterPalette.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                EncounterVerification(verified: link.verified)
            }
            if !link.verified {
                Text(DiscoverStrings.text(.unverifiedExplanation)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
            }
            if !link.title.isEmpty { Text(link.title).font(.headline) }
            if let description = link.description { Text(description) }
            EncounterTextChips(values: link.tags)
            if let language = link.mainLanguage { Text(language).font(.callout).foregroundStyle(EncounterPalette.inkSecondary) }
            if let opening = link.openingText { Text(opening) }
            DiscoverDivider()
            DiscoverDividedActions {
                Link(destination: link.url) {
                    DiscoverActionLabel(key: .openOriginal, symbol: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                }.buttonStyle(EncounterButtonStyle(.tertiary)).disabled(disabled)
                if !isSample {
                    DiscoverActionDivider()
                    Button(action: toggleSaved) {
                        DiscoverActionLabel(key: saved ? .unsaveLink : .saveLink,
                                            symbol: saved ? "bookmark.fill" : "bookmark")
                            .font(.subheadline.weight(.semibold))
                    }.buttonStyle(EncounterButtonStyle(.tertiary)).disabled(disabled)
                }
            }
            if let viewEncounter {
                Button(action: viewEncounter) {
                    Text(DiscoverStrings.text(.viewEncounter)).font(.footnote)
                }.buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false))
            }
            if !isSample {
                if let reportImpersonation {
                    Button(action: reportImpersonation) {
                        Text(DiscoverStrings.text(.reportImpersonation)).font(.footnote)
                    }.buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false)).disabled(disabled)
                }
            }
        }
    }
}

private extension EncounterLinkCard {
    var discoverSymbol: String {
        let host = url.host?.lowercased() ?? ""
        if host == "github.com" || source.lowercased().contains("github") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if ["zenn.dev", "qiita.com", "medium.com", "dev.to"].contains(host) {
            return "doc.richtext"
        }
        return "link"
    }
}

extension EncounterKind {
    var discoverLabel: DiscoverString {
        switch self { case .ambient: .ambient; case .session: .session; case .qr: .qrKind }
    }
}
