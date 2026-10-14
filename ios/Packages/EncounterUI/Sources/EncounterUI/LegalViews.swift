import SwiftUI

@MainActor
public struct LegalView: View {
    @ObservedObject private var model: LegalModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public init(model: LegalModel) { self.model = model }
    public var body: some View {
        SafetyPage(title: LegalStrings.text(.title)) {
            if !model.data.entries.isEmpty {
                EncounterSurfaceCard {
                    ForEach(model.data.entries, id: \.self) { entry in
                        Button { Task { await model.open(entry) } } label: {
                            EncounterIconRow(symbol: symbol(entry), title: LegalStrings.text(entry.stringKey),
                                             showsDivider: entry != model.data.entries.last)
                        }.buttonStyle(EncounterPlainButtonStyle()).disabled(model.isBusy)
                    }
                }
            }
            if let contact = model.data.contact {
                OnboardingCard {
                    let layout = dynamicTypeSize.isAccessibilitySize ?
                        AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) :
                        AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                    layout {
                        EncounterSymbolTile(symbol: "envelope")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(LegalStrings.text(.moderationContact)).font(.headline)
                            Text(contact).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let actions = dynamicTypeSize.isAccessibilitySize ?
                        AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                    actions {
                        Button(LegalStrings.text(.contact)) { Task { await model.contact() } }
                            .buttonStyle(EncounterButtonStyle(.secondary)).disabled(model.isBusy)
                        Button(LegalStrings.text(.copy)) { Task { await model.copy() } }
                            .buttonStyle(EncounterButtonStyle(.tertiary)).disabled(model.isBusy)
                    }
                }
            }
            if model.isBusy { EncounterProgress(SettingsStrings.text(.loading)) }
            if let operation = model.failedOperation {
                EncounterInlineError(message: LegalStrings.text(.openFailed), retryLabel: SettingsStrings.text(.retry),
                    disabled: model.isBusy, retry: { Task { await model.retry() } }) {
                    switch operation {
                    case .open(let url): Text(url.absoluteString).textSelection(.enabled)
                    case .contact(let address), .copy(let address): Text(address).textSelection(.enabled)
                    }
                }
            }
            Text(LegalStrings.text(.product)).font(.headline)
            if let version = model.data.version, !version.isEmpty {
                Text(SettingsStrings.labelStatus(LegalStrings.text(.version), version)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
            }
        }
        .navigationBarBackButtonHidden(true).interactiveDismissDisabled(model.isBusy)
        .environment(\.safetyPageIsPushed, true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EncounterBackButton(label: SettingsStrings.text(.back)) { model.back() }.disabled(model.isBusy)
            }
        }
    }

    private func symbol(_ entry: LegalEntry) -> String {
        switch entry {
        case .terms: "doc.text"
        case .privacy: "hand.raised"
        case .support: "questionmark.circle"
        }
    }
}

extension LegalEntry {
    var stringKey: LegalString {
        switch self { case .terms: .terms; case .privacy: .privacy; case .support: .support }
    }
}
