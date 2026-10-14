import SwiftUI
import UIKit

// Resolve the property wrapper instead of the SDK's compiler-plugin macro.
typealias SafetyViewState<Value> = State<Value>

private struct SafetyPagePushedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var safetyPageIsPushed: Bool {
        get { self[SafetyPagePushedKey.self] }
        set { self[SafetyPagePushedKey.self] = newValue }
    }
}

@MainActor
struct SafetyPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.safetyPageIsPushed) private var isPushed
    var body: some View {
        EncounterScreen(title: isPushed ? title : nil) { content }
            .navigationTitle(title).navigationBarTitleDisplayMode(isPushed ? .inline : .large)
    }
}

@MainActor
struct SafetyFailure: View {
    var error: ProfileActionError = .init(code: .unavailable)
    var fallback: SettingsString = .saveError
    var disabled = false
    let retry: @MainActor () async -> Void
    private var message: String {
        SettingsStrings.text(error.code == .unavailable ? fallback :
            SettingsErrorPresentation.message(error, screen: .visibility, discoveryOn: false))
    }
    var body: some View {
        EncounterInlineError(message: message, retryLabel: SettingsStrings.text(.retry), disabled: disabled) {
            Task { await retry() }
        }.accessibilityElement(children: .contain)
    }
}

@MainActor
public struct SafetyBlockedUsersView: View {
    @ObservedObject private var model: SafetyBlockedModel
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @SafetyViewState private var selectedBlock: SafetyBlock?
    public init(model: SafetyBlockedModel) { self.model = model }
    public var body: some View {
        SafetyPage(title: SafetyStrings.text(.blockedUsers)) {
            if model.isBusy { EncounterProgress(SettingsStrings.text(.loading)) }
            if let list = model.list {
                if list.blocks.isEmpty { Text(SafetyStrings.text(.empty)) }
                ForEach(list.blocks) { block in
                    OnboardingCard {
                        let layout = dynamicTypeSize.isAccessibilitySize ?
                            AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) :
                            AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                        layout {
                            EncounterSymbolTile(symbol: "nosign")
                            VStack(alignment: .leading, spacing: 8) {
                                Text(block.id).font(.body).textSelection(.enabled)
                                Text(block.placedDay.formatted(locale: locale)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button(SafetyStrings.text(.unblock)) { selectedBlock = block }
                                .buttonStyle(EncounterButtonStyle(.secondary, fullWidth: false)).disabled(model.isBusy)
                                .accessibilityLabel(SettingsStrings.labelStatus(SafetyStrings.text(.unblock), block.id))
                        }
                    }
                }
                if list.truncated { Text(SafetyStrings.text(.limitedList)).foregroundStyle(EncounterPalette.inkSecondary) }
            }
            if let error = model.error {
                SafetyFailure(error: error, fallback: model.failedBlockID == nil ? .listError : .saveError,
                              disabled: model.isBusy) { await model.retry() }
            }
            Text(SafetyStrings.text(.notRestored)).foregroundStyle(EncounterPalette.inkSecondary)
        }
        .navigationBarBackButtonHidden(true)
        .environment(\.safetyPageIsPushed, true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EncounterBackButton(label: SettingsStrings.text(.back)) { model.back() }.disabled(model.isBusy)
            }
        }
        .interactiveDismissDisabled(model.isBusy)
        .confirmationDialog(SafetyStrings.text(.confirmUnblock), isPresented: Binding(
            get: { selectedBlock != nil }, set: { if !$0 { selectedBlock = nil } }), titleVisibility: .visible) {
            if let block = selectedBlock {
                Button(SafetyStrings.text(.unblock)) {
                    selectedBlock = nil; Task { await model.unblock(block.id) }
                }
            }
            Button(SettingsStrings.text(.cancel), role: .cancel) { selectedBlock = nil }
        } message: { Text(SafetyStrings.text(.notRestored)) }
        .task { await model.load() }
    }
}

@MainActor
public struct SafetyReportSheet: View {
    @ObservedObject private var model: SafetyReportModel
    @SafetyViewState private var confirmsBlock = false
    public init(model: SafetyReportModel) { self.model = model }
    public var body: some View {
        NavigationStack {
            SafetyPage(title: SafetyStrings.text(.reportOrBlock)) {
                if model.acceptedReport != nil {
                    OnboardingCard {
                        Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(EncounterPalette.accent).accessibilityHidden(true)
                        Text(SafetyStrings.text(.submitted)).font(.headline)
                        Text(SafetyStrings.text(.acceptedHidden)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                    }
                } else {
                    reportForm
                }
                if model.isBusy { EncounterProgress(SettingsStrings.text(.loading)) }
                if model.isPendingHide { Text(SafetyStrings.text(.pending)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary) }
                if model.isBlockUnavailable {
                    Text(SafetyStrings.text(.blockUnavailable)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                } else if let error = model.error {
                    SafetyFailure(error: error, disabled: model.isBusy) { await model.retry() }
                }
                Button(SafetyStrings.text(model.acceptedReport == nil ? .block : .blockAlso), role: .destructive) {
                    confirmsBlock = true
                }.buttonStyle(EncounterButtonStyle(.destructive)).disabled(!model.canBlock)
                Text(SafetyStrings.text(.blockExplanation)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                Text(SafetyStrings.text(.review)).font(.callout).foregroundStyle(EncounterPalette.inkSecondary)
                if model.acceptedReport != nil {
                    Button(SafetyStrings.text(.done)) { model.done() }
                        .buttonStyle(EncounterButtonStyle(.primary)).disabled(model.isBusy)
                }
            }
            .toolbar {
                if model.acceptedReport == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(SettingsStrings.text(.cancel)) { Task { await model.cancel() } }
                            .buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false)).disabled(model.isBusy)
                    }
                }
            }
            .confirmationDialog(SafetyStrings.text(.block), isPresented: $confirmsBlock, titleVisibility: .visible) {
                Button(SafetyStrings.text(.block), role: .destructive) { Task { await model.block() } }
                Button(SettingsStrings.text(.cancel), role: .cancel) {}
            } message: { Text(SafetyStrings.text(.blockExplanation)) }
        }
        // Cancelling a failed submission requires fresh authorization before reopening.
        .interactiveDismissDisabled(true)
    }

    private var reportForm: some View {
        OnboardingCard {
            Text(SafetyStrings.text(.reason)).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(SafetyReportReason.allCases, id: \.self) { reason in
                EncounterRadioRow(label: SafetyStrings.text(reason.stringKey), selected: model.reason == reason) {
                    model.reason = reason
                }.disabled(model.state != .idle || model.isBusy)
            }
            if model.reason == .impersonation && model.link == nil {
                Text(SafetyStrings.text(.impersonationGuidance)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
            }
            Button(SafetyStrings.text(.submit)) { Task { await model.submit() } }
                .buttonStyle(EncounterButtonStyle(.primary)).disabled(!model.canSubmit)
            Text(SafetyStrings.text(.hidden)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
        }
    }
}

extension SafetyReportReason {
    var stringKey: SafetyString {
        switch self { case .spam: .spam; case .harassment: .harassment; case .impersonation: .impersonation; case .other: .other }
    }
}
