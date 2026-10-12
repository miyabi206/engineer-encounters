import SwiftUI

@MainActor
public struct LegalView: View {
    @ObservedObject private var model: LegalModel
    public init(model: LegalModel) { self.model = model }
    public var body: some View {
        SafetyPage(title: LegalStrings.text(.title)) {
            ForEach(model.data.entries, id: \.self) { entry in
                Button(LegalStrings.text(entry.stringKey)) { Task { await model.open(entry) } }.disabled(model.isBusy)
            }
            if let contact = model.data.contact {
                OnboardingCard {
                    Text(LegalStrings.text(.moderationContact)).font(.headline)
                    Text(contact).textSelection(.enabled)
                    Button(LegalStrings.text(.contact)) { Task { await model.contact() } }.disabled(model.isBusy)
                    Button(LegalStrings.text(.copy)) { Task { await model.copy() } }.disabled(model.isBusy)
                }
            }
            if model.isBusy { ProgressView(SettingsStrings.text(.loading)) }
            if let operation = model.failedOperation {
                Text(LegalStrings.text(.openFailed)).foregroundStyle(.red)
                switch operation {
                case .open(let url): Text(url.absoluteString).textSelection(.enabled)
                case .contact(let address), .copy(let address): Text(address).textSelection(.enabled)
                }
                Button(SettingsStrings.text(.retry)) { Task { await model.retry() } }.disabled(model.isBusy)
            }
            Text(LegalStrings.text(.product)).font(.headline)
            if let version = model.data.version, !version.isEmpty {
                Text(SettingsStrings.labelStatus(LegalStrings.text(.version), version)).foregroundStyle(.secondary)
            }
        }
        .navigationBarBackButtonHidden(true).interactiveDismissDisabled(model.isBusy)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(SettingsStrings.text(.back)) { model.back() }.disabled(model.isBusy)
            }
        }
    }
}

extension LegalEntry {
    var stringKey: LegalString {
        switch self { case .terms: .terms; case .privacy: .privacy; case .support: .support }
    }
}
