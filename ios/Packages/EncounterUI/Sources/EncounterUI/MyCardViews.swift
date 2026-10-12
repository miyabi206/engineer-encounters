import SwiftUI

@MainActor
public struct MyCardView: View {
    @ObservedObject private var model: MyCardModel
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    public init(model: MyCardModel) { self.model = model }
    public var body: some View {
        SafetyPage(title: MyCardStrings.text(.profile)) {
            Text(MyCardStrings.text(.preview)).font(.title2)
            Picker(MyCardStrings.text(.audience), selection: $model.audience) {
                Text(SettingsStrings.text(.everyoneEligible)).tag(MyCardAudience.everyoneEligible)
                Text(SettingsStrings.text(.compatibleOnly)).tag(MyCardAudience.compatibleOnly)
            }.pickerStyle(.menu)
            if model.isLoading { ProgressView(SettingsStrings.text(.loading)) }
            if model.failed {
                SafetyFailure(fallback: .listError) { await model.load() }
            } else if let data = model.data, let preview = model.preview {
                if !data.profile.discoveryOn { Text(MyCardStrings.text(.discoveryOff)).foregroundStyle(.secondary) }
                OnboardingCard {
                    EncounterIdentity(displayName: preview.displayName)
                    if let introduction = preview.introduction { Text(introduction) }
                    DiscoverInterestChips(interests: data.interests.filter { preview.interestIDs.contains($0.id) })
                    ForEach(ProfilePurpose.allCases.filter { preview.purposes.contains($0) }, id: \.self) { purpose in
                        Text(SettingsStrings.text(purpose == .discovery ? .discoveryPurpose : .collaborationPurpose))
                    }
                    if let contact = preview.contactDetail {
                        Text(SettingsStrings.text(.contactDetail)).font(.headline)
                        Text(contact).textSelection(.enabled)
                    }
                    if preview.isEmpty { Text(MyCardStrings.text(.emptyPreview)).foregroundStyle(.secondary) }
                }
                ForEach(preview.links) { link in
                    OnboardingCard {
                        Text(link.title).font(.headline)
                        Text(link.sourceLabel).foregroundStyle(.secondary)
                        EncounterVerification(verified: link.verified)
                        if !link.description.isEmpty { Text(link.description) }
                        if let language = link.mainLanguage, !language.isEmpty { Text(language) }
                        EncounterTextChips(values: link.tags)
                        if !link.openingText.isEmpty { Text(link.openingText) }
                        Button(LinkStrings.text(.openOriginal)) { Task { await model.open(link.url) } }
                            .accessibilityLabel(SettingsStrings.labelStatus(LinkStrings.text(.openOriginal), link.title))
                    }
                }
                if model.needsBasics { Text(MyCardStrings.text(.completeBasics)).foregroundStyle(.secondary) }
                if data.links.isEmpty { Text(MyCardStrings.text(.addLinks)).foregroundStyle(.secondary) }
            }
            if let url = model.failedURL {
                Text(MyCardStrings.text(.openFailed)).foregroundStyle(.red)
                Text(url.absoluteString).textSelection(.enabled)
                Button(SettingsStrings.text(.retry)) { Task { await model.open(url) } }
            }
            Button(SettingsStrings.text(.editProfile), action: model.navigation.editProfile)
            Button(LinkStrings.text(.myLinks), action: model.navigation.links)
            Button(SettingsStrings.text(.visibility), action: model.navigation.visibility)
        }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
    }
}
