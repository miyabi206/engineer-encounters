import SwiftUI
import UIKit

// Resolve the property wrapper instead of the SDK's compiler-plugin macro.
typealias SafetyViewState<Value> = State<Value>

@MainActor
struct SafetyPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding().frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title).navigationBarTitleDisplayMode(.large).tint(.teal)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(message).foregroundStyle(.red)
            Button(SettingsStrings.text(.retry)) { Task { await retry() } }.disabled(disabled)
        }.accessibilityElement(children: .contain)
    }
}

@MainActor
public struct SafetyBlockedUsersView: View {
    @ObservedObject private var model: SafetyBlockedModel
    @Environment(\.locale) private var locale
    @SafetyViewState private var selectedBlock: SafetyBlock?
    public init(model: SafetyBlockedModel) { self.model = model }
    public var body: some View {
        SafetyPage(title: SafetyStrings.text(.blockedUsers)) {
            if model.isBusy { ProgressView(SettingsStrings.text(.loading)) }
            if let list = model.list {
                if list.blocks.isEmpty { Text(SafetyStrings.text(.empty)) }
                ForEach(list.blocks) { block in
                    OnboardingCard {
                        Text(block.id).font(.body).textSelection(.enabled)
                        Text(block.placedDay.formatted(locale: locale)).foregroundStyle(.secondary)
                        Button(SafetyStrings.text(.unblock)) { selectedBlock = block }
                            .disabled(model.isBusy)
                            .accessibilityLabel(SettingsStrings.labelStatus(SafetyStrings.text(.unblock), block.id))
                    }
                }
                if list.truncated { Text(SafetyStrings.text(.limitedList)).foregroundStyle(.secondary) }
            }
            if let error = model.error {
                SafetyFailure(error: error, fallback: model.failedBlockID == nil ? .listError : .saveError,
                              disabled: model.isBusy) { await model.retry() }
            }
            Text(SafetyStrings.text(.notRestored)).foregroundStyle(.secondary)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(SettingsStrings.text(.back)) { model.back() }.disabled(model.isBusy)
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
                OnboardingCard {
                    Text(SafetyStrings.text(.reason)).font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(SafetyReportReason.allCases, id: \.self) { reason in
                        SelectionControl(label: SafetyStrings.text(reason.stringKey), selected: model.reason == reason) {
                            model.reason = reason
                        }.disabled(model.state != .idle || model.isBusy)
                    }
                    if model.reason == .impersonation && model.link == nil {
                        Text(SafetyStrings.text(.impersonationGuidance)).foregroundStyle(.secondary)
                    }
                    Button(SafetyStrings.text(.submit)) { Task { await model.submit() } }
                        .buttonStyle(.borderedProminent).disabled(!model.canSubmit)
                    Text(SafetyStrings.text(.hidden)).foregroundStyle(.secondary)
                }
                if model.isBusy { ProgressView(SettingsStrings.text(.loading)) }
                if case .accepted(.report) = model.state { Text(SafetyStrings.text(.submitted)) }
                if model.state.isPending { Text(SafetyStrings.text(.pending)).foregroundStyle(.secondary) }
                if let error = model.error {
                    SafetyFailure(error: error, disabled: model.isBusy) { await model.retry() }
                }
                Button(SafetyStrings.text(.block), role: .destructive) { confirmsBlock = true }
                    .disabled(model.state != .idle || model.isBusy)
                Text(SafetyStrings.text(.blockExplanation)).foregroundStyle(.secondary)
                Text(SafetyStrings.text(.review)).font(.callout).foregroundStyle(.secondary)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(SettingsStrings.text(.cancel)) { Task { await model.cancel() } }.disabled(model.isBusy)
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
}

extension SafetyReportReason {
    var stringKey: SafetyString {
        switch self { case .spam: .spam; case .harassment: .harassment; case .impersonation: .impersonation; case .other: .other }
    }
}
