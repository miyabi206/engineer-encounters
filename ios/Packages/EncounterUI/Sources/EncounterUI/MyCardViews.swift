import SwiftUI

@MainActor
public struct MyCardView: View {
    @ObservedObject private var model: MyCardModel
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public init(model: MyCardModel) { self.model = model }
    public var body: some View {
        SafetyPage(title: MyCardStrings.text(.profile)) {
            Text(MyCardStrings.text(.preview)).foregroundStyle(EncounterPalette.inkSecondary)
            EncounterSegmentedControl(segments: [
                .init(MyCardAudience.everyoneEligible, label: SettingsStrings.text(.everyoneEligible)),
                .init(MyCardAudience.compatibleOnly, label: SettingsStrings.text(.compatibleOnly))
            ], selection: $model.audience, label: MyCardStrings.text(.audience))
            if model.isLoading { EncounterProgress(SettingsStrings.text(.loading)) }
            if model.failed {
                SafetyFailure(fallback: .listError) { await model.load() }
            } else if let data = model.data, let preview = model.preview {
                if !data.profile.discoveryOn { EncounterNotice(MyCardStrings.text(.discoveryOff)) }
                OnboardingCard {
                    EncounterIdentity(displayName: preview.displayName)
                    if let introduction = preview.introduction { Text(introduction) }
                    DiscoverInterestChips(interests: data.interests.filter { preview.interestIDs.contains($0.id) })
                    EncounterFlowLayout(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                        ForEach(ProfilePurpose.allCases.filter { preview.purposes.contains($0) }, id: \.self) { purpose in
                            EncounterChip(label: SettingsStrings.text(purpose == .discovery ? .discoveryPurpose : .collaborationPurpose), tone: .neutral)
                        }
                    }
                    if let contact = preview.contactDetail {
                        Text(SettingsStrings.text(.contactDetail)).font(.headline)
                        Text(contact).textSelection(.enabled)
                    }
                    if preview.isEmpty { EncounterNotice(MyCardStrings.text(.emptyPreview)) }
                }
                ForEach(preview.links) { link in
                    OnboardingCard {
                        let layout = dynamicTypeSize.isAccessibilitySize ?
                            AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) :
                            AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                        layout {
                            EncounterSymbolTile(symbol: sourceSymbol(link.source))
                            VStack(alignment: .leading, spacing: 8) {
                                Text(link.title).font(.headline)
                                Text(link.sourceLabel).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                                EncounterVerification(verified: link.verified)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !link.description.isEmpty { Text(link.description) }
                        if let language = link.mainLanguage, !language.isEmpty { Text(language) }
                        EncounterTextChips(values: link.tags)
                        if !link.openingText.isEmpty { Text(link.openingText) }
                        Button { Task { await model.open(link.url) } } label: {
                            HStack {
                                Text(LinkStrings.text(.openOriginal))
                                Image(systemName: "arrow.up.right.square").accessibilityHidden(true)
                            }
                        }.buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false))
                            .accessibilityLabel(SettingsStrings.labelStatus(LinkStrings.text(.openOriginal), link.title))
                    }
                }
                if model.needsBasics { EncounterNotice(MyCardStrings.text(.completeBasics)) }
                if data.links.isEmpty { EncounterNotice(MyCardStrings.text(.addLinks)) }
            }
            if let url = model.failedURL {
                EncounterInlineError(message: MyCardStrings.text(.openFailed), retryLabel: SettingsStrings.text(.retry),
                    retry: { Task { await model.open(url) } }) {
                    Text(url.absoluteString).textSelection(.enabled)
                }
            }
            EncounterSurfaceCard {
                Button(action: model.navigation.editProfile) {
                    EncounterIconRow(symbol: "pencil", title: SettingsStrings.text(.editProfile), showsDivider: true)
                }.buttonStyle(EncounterPlainButtonStyle())
                Button(action: model.navigation.links) {
                    EncounterIconRow(symbol: "link", title: LinkStrings.text(.myLinks), showsDivider: true)
                }.buttonStyle(EncounterPlainButtonStyle())
                Button(action: model.navigation.visibility) {
                    EncounterIconRow(symbol: "eye", title: SettingsStrings.text(.visibility))
                }.buttonStyle(EncounterPlainButtonStyle())
            }
        }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
    }

    private func sourceSymbol(_ source: LinkSource) -> String {
        switch source {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .qiita, .zenn: "doc.richtext"
        case .other: "link"
        }
    }
}
