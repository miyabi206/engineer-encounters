import SwiftUI

// Use the property wrapper, not the SDK's same-named compiler macro.
typealias LinkViewState<Value> = State<Value>

@MainActor
public struct LinkListView: View {
    @ObservedObject private var model: LinksModel
    private let back: @MainActor () -> Void
    private let discoverySettings: (@MainActor () -> Void)?

    public init(model: LinksModel, back: @escaping @MainActor () -> Void,
                discoverySettings: (@MainActor () -> Void)? = nil) {
        self.model = model; self.back = back; self.discoverySettings = discoverySettings
    }
    public var body: some View {
        switch model.route {
        case .add: LinkAddView(model: model)
        case .edit: LinkEditView(model: model, discoverySettings: discoverySettings)
        case .list:
            LinkPage(title: .myLinks, backLabel: .back, busy: model.isBusy, back: back,
                     subtitle: .platformExplanation) {
                LinkOwnedList(model: model, allowsReordering: true)
                EncounterNotice(LinkStrings.text(.identityWarning), kind: .warning)
            }.task { if !model.hasLoadedLinks { await model.loadLinks() } }
        }
    }
}

@MainActor
public struct FirstLinkView: View {
    @ObservedObject private var model: OnboardingModel
    public init(model: OnboardingModel) { self.model = model }
    public var body: some View {
        if let links = model.linkModel { FirstLinkContent(onboarding: model, links: links) }
    }
}

@MainActor
private struct FirstLinkContent: View {
    @ObservedObject var onboarding: OnboardingModel
    @ObservedObject var links: LinksModel
    var body: some View {
        switch links.route {
        case .add: LinkAddView(model: links)
        case .edit: LinkEditView(model: links, discoverySettings: onboarding.linkDiscoverySettings)
        case .list:
            LinkPage(title: .firstLink, backLabel: .back, busy: onboarding.isBusy, back: onboarding.back,
                     subtitle: .platformExplanation, bottomBar: AnyView(continueButton)) {
                LinkOwnedList(model: links, allowsReordering: false)
                EncounterNotice(LinkStrings.text(.identityWarning), kind: .warning)
            }.task { if !links.hasLoadedLinks { await links.loadLinks() } }
        }
    }

    private var continueButton: some View {
        Button(LinkStrings.text(.continueAction), action: onboarding.continueFirstLink)
            .buttonStyle(EncounterButtonStyle(.primary))
            .disabled(!links.hasLoadedLinks || links.links.isEmpty || onboarding.isBusy)
    }
}

@MainActor
private struct LinkOwnedList: View {
    @ObservedObject var model: LinksModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let allowsReordering: Bool
    var body: some View {
        let addLayout = allowsReordering && !dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        addLayout {
            Button(action: model.beginAdd) {
                Label { Text(LinkStrings.text(.addLink)) } icon: {
                    Image(systemName: "plus.circle.fill").accessibilityHidden(true)
                }
            }.buttonStyle(EncounterButtonStyle(.primary)).disabled(!model.canAdd)
            if model.hasLoadedLinks {
                Text(LinkStrings.counter(model.links.count, limit: LinkValidation.linkLimit))
                    .font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
            }
        }
        if model.isBusy { LinkProgress() }
        LinkFailure(model: model)
        if model.hasLoadedLinks {
            if model.links.isEmpty {
                EncounterNotice(LinkStrings.text(.noLinks))
                EncounterNotice(LinkStrings.text(.linkRequired))
            }
            if model.links.count >= LinkValidation.linkLimit {
                EncounterNotice(LinkStrings.text(.linkLimit))
            }
            ForEach(model.links) { link in
                OnboardingCard {
                    LinkPreviewCard(draft: LinkPreviewDraft(link: link))
                    Divider().overlay(EncounterPalette.border)
                    let actions = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
                        : AnyLayout(HStackLayout(spacing: 8))
                    actions {
                        Button(LinkStrings.text(.edit)) { model.beginEdit(link) }
                            .buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false))
                            .disabled(model.isBusy)
                            .accessibilityLabel(LinkStrings.label(LinkStrings.text(.edit), value: link.title))
                        SwiftUI.Link(LinkStrings.text(.openOriginal), destination: link.url)
                            .buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false))
                            .accessibilityLabel(LinkStrings.label(LinkStrings.text(.openOriginal), value: link.title))
                    }.frame(maxWidth: .infinity, alignment: .trailing)
                    if allowsReordering && model.links.count > 1 {
                        let moves = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
                            : AnyLayout(HStackLayout(spacing: 8))
                        moves {
                            Button { Task { await model.move(link.id, offset: -1) } } label: {
                                Image(systemName: "arrow.up").accessibilityHidden(true)
                            }
                            .buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false))
                            .disabled(model.isBusy || model.links.first?.id == link.id)
                            .accessibilityLabel(LinkStrings.label(link.title, value: LinkStrings.text(.moveUp)))
                            Button { Task { await model.move(link.id, offset: 1) } } label: {
                                Image(systemName: "arrow.down").accessibilityHidden(true)
                            }
                            .buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false))
                            .disabled(model.isBusy || model.links.last?.id == link.id)
                            .accessibilityLabel(LinkStrings.label(link.title, value: LinkStrings.text(.moveDown)))
                        }.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }
}

@MainActor
public struct LinkAddView: View {
    @ObservedObject private var model: LinksModel
    public init(model: LinksModel) { self.model = model }
    public var body: some View {
        LinkPage(title: .addTitle, backLabel: .cancel, busy: model.isBusy, back: model.cancelAdd) {
            OnboardingCard {
                ForEach(LinkSource.allCases, id: \.self) { source in
                    EncounterRadioRow(label: LinkStrings.source(source), selected: model.selectedSource == source) {
                        model.selectedSource = source
                    }.disabled(model.isBusy)
                    if source != .github {
                        Text(LinkStrings.label(LinkStrings.source(source), value: LinkStrings.text(.notAvailable)))
                            .font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                    }
                }
            }
            if model.selectedSource == .github {
                githubContent
            } else if model.selectedSource != nil {
                Text(LinkStrings.text(.notAvailable)).foregroundStyle(EncounterPalette.inkSecondary)
            } else {
                Text(LinkStrings.text(.chooseSource)).foregroundStyle(EncounterPalette.inkSecondary)
            }
        }.task(id: model.selectedSource) {
            if model.selectedSource == .github {
                if !model.hasLoadedConnection { await model.loadConnection() }
                else if model.connection.isConnected && !model.hasLoadedRepositories { await model.loadRepositories(page: 1) }
            }
        }
    }

    @ViewBuilder private var githubContent: some View {
        OnboardingCard {
            EncounterSymbolTile(symbol: "chevron.left.forwardslash.chevron.right")
            if model.connection == .connecting {
                EncounterProgress(LinkStrings.text(.connecting))
            } else if model.connection.isConnected {
                if let handle = model.connection.handle {
                    Text(String(format: LinkStrings.text(.connected), locale: Locale.current, handle))
                } else { Text(LinkStrings.text(.connectedWithoutHandle)) }
                if model.draft != nil {
                    Button(LinkStrings.text(.continueAction), action: model.returnToEditor)
                        .buttonStyle(EncounterButtonStyle(.secondary)).disabled(model.isBusy)
                }
                Text(LinkStrings.text(.repositories)).font(.headline).accessibilityAddTraits(.isHeader)
                if model.hasLoadedRepositories {
                    if model.paging.repositories.isEmpty { Text(LinkStrings.text(.noItems)) }
                    ForEach(model.paging.repositories) { repository in
                        LinkRepositoryRow(repository: repository, model: model)
                    }
                    Text(String(format: LinkStrings.text(.page), locale: Locale.current, model.paging.page))
                        .font(.caption)
                    if let previous = model.paging.previousPage {
                        Button(LinkStrings.text(.previousPage)) { Task { await model.loadRepositories(page: previous) } }
                            .buttonStyle(EncounterButtonStyle(.secondary))
                            .disabled(model.isBusy)
                    }
                    if let next = model.paging.nextPage {
                        Button(LinkStrings.text(.nextPage)) { Task { await model.loadRepositories(page: next) } }
                            .buttonStyle(EncounterButtonStyle(.secondary))
                            .disabled(model.isBusy)
                    }
                }
            } else {
                if model.connectionCancelled { EncounterNotice(LinkStrings.text(.connectionCancelled)) }
                if model.connection == .failed { EncounterNotice(LinkStrings.text(.connectionFailed), kind: .warning) }
                Button(LinkStrings.text(.connectGitHub)) { Task { await model.connectGitHub() } }
                    .disabled(model.isBusy).buttonStyle(EncounterButtonStyle(.primary))
            }
            if model.isBusy && model.connection != .connecting { LinkProgress() }
            LinkFailure(model: model)
        }
    }
}

@MainActor
private struct LinkRepositoryRow: View {
    let repository: GitHubRepositoryChoice
    @ObservedObject var model: LinksModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 8) {
                Text(repository.repositoryName).font(.headline)
                Text(repository.url.absoluteString).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(LinkStrings.text(.select)) { Task { await model.preview(repository) } }
                .buttonStyle(EncounterButtonStyle(.secondary, fullWidth: false))
                .disabled(!model.canAdd)
                .accessibilityLabel(LinkStrings.label(LinkStrings.text(.select), value: repository.repositoryName))
        }
        Divider().overlay(EncounterPalette.border)
    }
}

@MainActor
public struct LinkEditView: View {
    @ObservedObject private var model: LinksModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let discoverySettings: (@MainActor () -> Void)?
    @LinkViewState private var confirmsDiscard = false
    @LinkViewState private var confirmsDelete = false

    public init(model: LinksModel, discoverySettings: (@MainActor () -> Void)? = nil) {
        self.model = model; self.discoverySettings = discoverySettings
    }
    public var body: some View {
        LinkPage(title: .editLink, backLabel: .cancel, busy: model.isBusy, back: cancel,
                 save: { Task { await model.save() } }, canSave: model.canSave) {
            if let draft = model.draft {
                OnboardingCard {
                    Text(LinkStrings.text(.originalURL)).font(.headline)
                    SwiftUI.Link(draft.url.absoluteString, destination: draft.url)
                        .buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false))
                        .accessibilityLabel(LinkStrings.label(LinkStrings.text(.originalURL), value: draft.url.absoluteString))
                    Text(LinkStrings.source(draft.source)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                    Text(LinkStrings.label(LinkStrings.text(.source), value: draft.sourceLabel))
                    textField(.title, field: .title, value: binding(\.title), limit: LinkValidation.titleLimit, required: true)
                    textField(.description, field: .description, value: binding(\.description), limit: LinkValidation.descriptionLimit)
                    tagsEditor(draft)
                    textField(.mainLanguage, field: .mainLanguage, value: languageBinding, limit: LinkValidation.languageLimit)
                    textField(.openingText, field: .openingText, value: binding(\.openingText), limit: LinkValidation.openingTextLimit)
                    EncounterBadge(LinkStrings.text(draft.verified ? .verified : .unverified),
                                   style: draft.verified ? .verified : .unverified)
                    Button(LinkStrings.text(.refresh)) { Task { await model.refresh() } }
                        .buttonStyle(EncounterButtonStyle(.secondary)).disabled(model.isBusy)
                }.disabled(model.isBusy)
                OnboardingCard {
                    Text(LinkStrings.text(.visibility)).font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(VisibilityLevel.allCases, id: \.self) { level in
                        EncounterRadioRow(label: LinkStrings.visibility(level), selected: draft.visibility == level) {
                            model.draft?.visibility = level
                        }.disabled(model.isBusy)
                    }
                    if draft.visibility == nil { Text(LinkStrings.text(.chooseVisibility)).foregroundStyle(EncounterPalette.inkSecondary) }
                    if model.error?.fields.contains(.visibility) == true {
                        Text(LinkStrings.text(.invalidField)).foregroundStyle(EncounterPalette.destructive)
                    }
                    Text(SettingsStrings.text(.everyoneExplanation)).font(.caption)
                    Text(SettingsStrings.text(.compatibleExplanation)).font(.caption)
                    Text(SettingsStrings.text(.privateExplanation)).font(.caption)
                }
                OnboardingCard {
                    Text(LinkStrings.text(.preview)).font(.headline).accessibilityAddTraits(.isHeader)
                    LinkPreviewCard(draft: draft)
                    EncounterNotice(LinkStrings.text(.identityWarning), kind: .warning)
                }
                if model.isBusy { LinkProgress() }
                LinkFailure(model: model)
                if draft.existingLinkID != nil {
                    Button(LinkStrings.text(.delete), role: .destructive) { confirmsDelete = true }
                        .buttonStyle(EncounterButtonStyle(.destructive))
                        .disabled(!model.canDelete)
                    if !LinkValidation.canDelete(count: model.links.count, discoveryOn: model.discoveryOn) || model.error?.isLastLink == true {
                        EncounterNotice(LinkStrings.text(.lastLink))
                        if let discoverySettings {
                            Button(LinkStrings.text(.discoverySettings), action: discoverySettings)
                                .buttonStyle(EncounterButtonStyle(.secondary)).disabled(model.isBusy)
                        }
                    }
                }
            }
        }
        .confirmationDialog(LinkStrings.text(.discard), isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button(LinkStrings.text(.discard), role: .destructive, action: model.cancelEditor)
            Button(LinkStrings.text(.cancel), role: .cancel) {}
        }
        .confirmationDialog(LinkStrings.text(.delete), isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(LinkStrings.text(.delete), role: .destructive) { Task { await model.deleteConfirmed() } }
            Button(LinkStrings.text(.cancel), role: .cancel) {}
        } message: { Text(LinkStrings.text(.deleteExplanation)) }
        .sheet(isPresented: Binding(get: { model.replacement != nil }, set: { if !$0 { model.cancelReplacement() } })) {
            LinkReplacementView(model: model)
        }
    }
    private func cancel() {
        if model.hasEdits { confirmsDiscard = true } else { model.cancelEditor() }
    }
    private var languageBinding: Binding<String> {
        Binding(get: { model.draft?.mainLanguage ?? "" }, set: { model.draft?.mainLanguage = $0.isEmpty ? nil : $0 })
    }
    private func binding(_ keyPath: WritableKeyPath<LinkPreviewDraft, String>) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: keyPath] ?? "" }, set: { model.draft?[keyPath: keyPath] = $0 })
    }
    private func textField(_ label: LinkString, field: LinkField, value: Binding<String>,
                           limit: Int? = nil, required: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EncounterField(LinkStrings.text(label), text: value, multiline: true)
            if let limit {
                Text(LinkStrings.counter(LinkValidation.count(value.wrappedValue), limit: limit))
                    .font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                if LinkValidation.count(value.wrappedValue) > limit {
                    Text(String(format: LinkStrings.text(.tooLong), locale: Locale.current, limit)).foregroundStyle(EncounterPalette.destructive)
                }
            }
            if required && LinkValidation.count(value.wrappedValue) == 0 {
                Text(LinkStrings.text(.requiredTitle)).foregroundStyle(EncounterPalette.inkSecondary)
            }
            if model.error?.fields.contains(field) == true {
                Text(LinkStrings.text(.invalidField)).foregroundStyle(EncounterPalette.destructive)
            }
        }
    }
    private func tagsEditor(_ draft: LinkPreviewDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LinkStrings.text(.tags)).font(.headline)
            ForEach(draft.tags.indices, id: \.self) { index in
                let tag = Binding<String>(get: {
                    guard let tags = model.draft?.tags, tags.indices.contains(index) else { return "" }
                    return tags[index]
                }, set: { value in
                    guard var current = model.draft, current.tags.indices.contains(index) else { return }
                    current.tags[index] = value; model.draft = current
                })
                VStack(alignment: .leading, spacing: 8) {
                    let row = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(spacing: 8))
                    row {
                        LinkTagInput(text: tag)
                        Button(LinkStrings.text(.removeTag)) { model.removeTag(at: index) }
                            .buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false))
                            .accessibilityLabel(LinkStrings.label(LinkStrings.text(.removeTag), value: draft.tags[index]))
                    }
                    Text(LinkStrings.counter(LinkValidation.count(draft.tags[index]), limit: LinkValidation.tagLengthLimit))
                        .font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                    if !ProfileValidation.validRequiredText(draft.tags[index], limit: LinkValidation.tagLengthLimit) {
                        Text(LinkStrings.text(.invalidField)).foregroundStyle(EncounterPalette.destructive)
                    }
                }
            }
            Text(LinkStrings.counter(draft.tags.count, limit: LinkValidation.tagLimit)).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
            if draft.tags.count > LinkValidation.tagLimit || model.error?.fields.contains(.tags) == true {
                Text(LinkStrings.text(.invalidField)).foregroundStyle(EncounterPalette.destructive)
            }
            Button(LinkStrings.text(.addTag)) { model.draft?.tags.append("") }
                .buttonStyle(EncounterButtonStyle(.secondary))
                .disabled(draft.tags.count >= LinkValidation.tagLimit)
        }
    }
}

@MainActor
private struct LinkReplacementView: View {
    @ObservedObject var model: LinksModel
    var body: some View {
        LinkPage(title: .replaceEdits, backLabel: .cancel, busy: false, back: model.cancelReplacement) {
            if let fresh = model.replacement {
                OnboardingCard {
                    LinkPreviewCard(draft: model.draft?.replacingMetadata(with: fresh) ?? fresh)
                    Text(LinkStrings.label(LinkStrings.text(.source), value: fresh.sourceLabel))
                    Text(LinkStrings.label(LinkStrings.text(.mainLanguage), value: fresh.mainLanguage ?? ""))
                    Text(LinkStrings.label(LinkStrings.text(.tags), value: SettingsStrings.joined(fresh.tags)))
                    Text(LinkStrings.label(LinkStrings.text(.description), value: fresh.description))
                    Text(LinkStrings.label(LinkStrings.text(.openingText), value: fresh.openingText))
                }
                Button(LinkStrings.text(.replace), action: model.acceptReplacement).buttonStyle(EncounterButtonStyle(.primary))
            }
        }.presentationDragIndicator(.visible)
    }
}

@MainActor
struct LinkPreviewCard: View {
    let draft: LinkPreviewDraft
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var sourceSymbol: String {
        switch draft.source {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .qiita, .zenn: "doc.richtext"
        case .other: "link"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                EncounterSymbolTile(symbol: sourceSymbol)
                VStack(alignment: .leading, spacing: 8) {
                    Text(draft.sourceLabel).font(.caption).foregroundStyle(EncounterPalette.inkSecondary)
                    Text(draft.title).font(.headline)
                }
            }
            if !draft.description.isEmpty { Text(draft.description).foregroundStyle(EncounterPalette.inkSecondary) }
            if let language = draft.mainLanguage, !language.isEmpty { Text(language).font(.caption) }
            EncounterFlowLayout(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                ForEach(Array(draft.tags.enumerated()), id: \.offset) { _, tag in
                    EncounterChip(label: tag)
                }
            }
            if !draft.openingText.isEmpty { Text(draft.openingText) }
            EncounterFlowLayout(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                EncounterBadge(LinkStrings.text(draft.verified ? .verified : .unverified),
                               style: draft.verified ? .verified : .unverified)
                EncounterBadge(LinkStrings.visibility(draft.visibility), style: .visibility)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct LinkPage<Content: View>: View {
    let title: LinkString
    let backLabel: LinkString
    let busy: Bool
    let back: @MainActor () -> Void
    var save: (@MainActor () -> Void)?
    var canSave = false
    var subtitle: LinkString?
    var bottomBar: AnyView?
    @ViewBuilder let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if let bottomBar {
                EncounterScreen { pageContent } bottomBar: { bottomBar }
            } else {
                EncounterScreen { pageContent }
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            let header = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
            header {
                if backLabel == .back {
                    EncounterBackButton(label: LinkStrings.text(backLabel), action: back).disabled(busy)
                } else {
                    Button(LinkStrings.text(backLabel), action: back)
                        .buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false)).disabled(busy)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if let save {
                    Button(LinkStrings.text(.save), action: save)
                        .bold().buttonStyle(EncounterButtonStyle(.tertiary, fullWidth: false)).disabled(!canSave)
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .trailing)
                }
            }
            VStack(alignment: title == .firstLink ? .center : .leading, spacing: 12) {
                Text(LinkStrings.text(title)).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(LinkStrings.text(subtitle)).foregroundStyle(EncounterPalette.inkSecondary) }
            }
            .multilineTextAlignment(title == .firstLink ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: title == .firstLink ? .center : .leading)
            .padding(.bottom, 8)
            content
        }
    }
}

@MainActor
private struct LinkTagInput: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var height = 52.0

    var body: some View {
        TextField(LinkStrings.text(.tags), text: $text)
            .focused($focused).textFieldStyle(.plain)
            .accessibilityLabel(LinkStrings.text(.tags))
            .padding(16).frame(maxWidth: .infinity, minHeight: max(44, height))
            .background(EncounterPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(EncounterPalette.controlOutline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .simultaneousGesture(TapGesture().onEnded { if isEnabled { focused = true } })
    }
}

@MainActor
private struct LinkProgress: View {
    var body: some View {
        EncounterProgress(LinkStrings.text(.loading))
    }
}

@MainActor
private struct LinkFailure: View {
    @ObservedObject var model: LinksModel
    var body: some View {
        if let error = model.error {
            VStack(alignment: .leading, spacing: 8) {
                if let operation = model.failedOperation, operation != .delete, model.canRetry {
                    EncounterInlineError(message: LinkStrings.text(message(error)), retryLabel: LinkStrings.retryLabel(operation)) {
                        Task { await model.retry(operation) }
                    }
                } else {
                    Text(LinkStrings.text(message(error))).foregroundStyle(EncounterPalette.destructive)
                }
            }.accessibilityElement(children: .contain)
        } else if model.canRetry {
            retryButton
        }
    }
    @ViewBuilder private var retryButton: some View {
        if let operation = model.failedOperation, operation != .delete, model.canRetry {
            Button(LinkStrings.retryLabel(operation)) { Task { await model.retry(operation) } }
                .buttonStyle(EncounterButtonStyle(.secondary, fullWidth: false))
        }
    }
    private func message(_ error: LinkActionError) -> LinkString {
        if error.isLastLink { return .lastLink }
        if error.requires("refresh_confirmation") { return .replaceEdits }
        if error.requires("github") { return .connectGitHub }
        if error.requires("github_reader") { return .readerFailure }
        switch error.code {
        case .lastLink: return .lastLink
        case .limitReached: return .linkLimit
        case .sourceUnavailable: return .notAvailable
        case .invalidInput: return .invalidField
        case .unavailable, .prerequisiteMissing:
            switch model.failedOperation {
            case .connect: return .connectionFailed
            case .save: return .saveError
            case .delete: return .deleteError
            case .reorder: return .reorderError
            case .refresh: return .refreshError
            default: return .loadError
            }
        }
    }
}
