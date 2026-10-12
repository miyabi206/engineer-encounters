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
            LinkPage(title: .myLinks, backLabel: .back, busy: model.isBusy, back: back) {
                Text(LinkStrings.text(.platformExplanation))
                LinkOwnedList(model: model, allowsReordering: true)
                Text(LinkStrings.text(.identityWarning)).font(.callout)
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
            LinkPage(title: .firstLink, backLabel: .back, busy: onboarding.isBusy, back: onboarding.back) {
                Text(LinkStrings.text(.platformExplanation))
                LinkOwnedList(model: links, allowsReordering: false)
                Text(LinkStrings.text(.identityWarning)).font(.callout)
                Button(LinkStrings.text(.continueAction), action: onboarding.continueFirstLink)
                    .buttonStyle(.borderedProminent)
                    .disabled(!links.hasLoadedLinks || links.links.isEmpty || onboarding.isBusy)
            }.task { if !links.hasLoadedLinks { await links.loadLinks() } }
        }
    }
}

@MainActor
private struct LinkOwnedList: View {
    @ObservedObject var model: LinksModel
    let allowsReordering: Bool
    var body: some View {
        Button(LinkStrings.text(.addLink), action: model.beginAdd)
            .buttonStyle(.borderedProminent).disabled(!model.canAdd)
        if model.hasLoadedLinks {
            Text(LinkStrings.counter(model.links.count, limit: LinkValidation.linkLimit))
                .font(.caption).foregroundStyle(.secondary)
        }
        if model.isBusy { LinkProgress() }
        LinkFailure(model: model)
        if model.hasLoadedLinks {
            if model.links.isEmpty {
                Text(LinkStrings.text(.noLinks))
                Text(LinkStrings.text(.linkRequired)).foregroundStyle(.secondary)
            }
            if model.links.count >= LinkValidation.linkLimit {
                Text(LinkStrings.text(.linkLimit)).foregroundStyle(.secondary)
            }
            ForEach(model.links) { link in
                OnboardingCard {
                    LinkPreviewCard(draft: LinkPreviewDraft(link: link))
                    Button(LinkStrings.text(.edit)) { model.beginEdit(link) }
                        .disabled(model.isBusy)
                        .accessibilityLabel(LinkStrings.label(LinkStrings.text(.edit), value: link.title))
                    SwiftUI.Link(LinkStrings.text(.openOriginal), destination: link.url)
                        .accessibilityLabel(LinkStrings.label(LinkStrings.text(.openOriginal), value: link.title))
                    if allowsReordering && model.links.count > 1 {
                        Button(LinkStrings.text(.moveUp)) { Task { await model.move(link.id, offset: -1) } }
                            .disabled(model.isBusy || model.links.first?.id == link.id)
                            .accessibilityLabel(LinkStrings.label(link.title, value: LinkStrings.text(.moveUp)))
                        Button(LinkStrings.text(.moveDown)) { Task { await model.move(link.id, offset: 1) } }
                            .disabled(model.isBusy || model.links.last?.id == link.id)
                            .accessibilityLabel(LinkStrings.label(link.title, value: LinkStrings.text(.moveDown)))
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
                    SelectionControl(label: LinkStrings.source(source), selected: model.selectedSource == source) {
                        model.selectedSource = source
                    }.disabled(model.isBusy)
                    if source != .github {
                        Text(LinkStrings.label(LinkStrings.source(source), value: LinkStrings.text(.notAvailable)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.selectedSource == .github {
                githubContent
            } else if model.selectedSource != nil {
                Text(LinkStrings.text(.notAvailable)).foregroundStyle(.secondary)
            } else {
                Text(LinkStrings.text(.chooseSource)).foregroundStyle(.secondary)
            }
        }.task(id: model.selectedSource) {
            if model.selectedSource == .github && !model.hasLoadedConnection { await model.loadConnection() }
        }
    }

    @ViewBuilder private var githubContent: some View {
        OnboardingCard {
            if model.connection == .connecting {
                ProgressView(LinkStrings.text(.connecting)).accessibilityLabel(LinkStrings.text(.connecting))
            } else if let handle = model.connection.handle {
                Text(String(format: LinkStrings.text(.connected), locale: Locale.current, handle))
                Text(LinkStrings.text(.repositories)).font(.headline).accessibilityAddTraits(.isHeader)
                if model.hasLoadedRepositories {
                    if model.paging.repositories.isEmpty { Text(LinkStrings.text(.noItems)) }
                    ForEach(model.paging.repositories) { repository in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(repository.name).font(.headline)
                            Text(repository.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                            Button(LinkStrings.text(.select)) { Task { await model.preview(repository) } }
                                .disabled(!model.canAdd)
                                .accessibilityLabel(LinkStrings.label(LinkStrings.text(.select), value: repository.name))
                        }
                    }
                    Text(String(format: LinkStrings.text(.page), locale: Locale.current, model.paging.page))
                        .font(.caption)
                    if let previous = model.paging.previousPage {
                        Button(LinkStrings.text(.previousPage)) { Task { await model.loadRepositories(page: previous) } }
                            .disabled(model.isBusy)
                    }
                    if let next = model.paging.nextPage {
                        Button(LinkStrings.text(.nextPage)) { Task { await model.loadRepositories(page: next) } }
                            .disabled(model.isBusy)
                    }
                }
            } else {
                if model.connectionCancelled { Text(LinkStrings.text(.connectionCancelled)) }
                if model.connection == .failed { Text(LinkStrings.text(.connectionFailed)).foregroundStyle(.red) }
                Button(LinkStrings.text(.connectGitHub)) { Task { await model.connectGitHub() } }
                    .disabled(model.isBusy).buttonStyle(.borderedProminent)
            }
            if model.isBusy && model.connection != .connecting { LinkProgress() }
            LinkFailure(model: model)
        }
    }
}

@MainActor
public struct LinkEditView: View {
    @ObservedObject private var model: LinksModel
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
                        .accessibilityLabel(LinkStrings.label(LinkStrings.text(.originalURL), value: draft.url.absoluteString))
                    Text(LinkStrings.source(draft.source)).font(.caption).foregroundStyle(.secondary)
                    textField(.source, field: .sourceLabel, value: binding(\.sourceLabel))
                    textField(.title, field: .title, value: binding(\.title), limit: LinkValidation.titleLimit, required: true)
                    textField(.description, field: .description, value: binding(\.description), limit: LinkValidation.descriptionLimit)
                    tagsEditor(draft)
                    textField(.mainLanguage, field: .mainLanguage, value: binding(\.mainLanguage), limit: LinkValidation.languageLimit)
                    textField(.openingText, field: .openingText, value: binding(\.openingText), limit: LinkValidation.openingTextLimit)
                    Text(LinkStrings.text(draft.verified ? .verified : .unverified))
                    Button(LinkStrings.text(.refresh)) { Task { await model.refresh() } }.disabled(model.isBusy)
                }.disabled(model.isBusy)
                OnboardingCard {
                    Text(LinkStrings.text(.visibility)).font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(VisibilityLevel.allCases, id: \.self) { level in
                        SelectionControl(label: LinkStrings.visibility(level), selected: draft.visibility == level) {
                            model.draft?.visibility = level
                        }.disabled(model.isBusy)
                    }
                    if draft.visibility == nil { Text(LinkStrings.text(.chooseVisibility)).foregroundStyle(.secondary) }
                    if model.error?.fields.contains(.visibility) == true {
                        Text(LinkStrings.text(.invalidField)).foregroundStyle(.red)
                    }
                    Text(SettingsStrings.text(.everyoneExplanation)).font(.caption)
                    Text(SettingsStrings.text(.compatibleExplanation)).font(.caption)
                    Text(SettingsStrings.text(.privateExplanation)).font(.caption)
                }
                OnboardingCard {
                    Text(LinkStrings.text(.preview)).font(.headline).accessibilityAddTraits(.isHeader)
                    LinkPreviewCard(draft: draft)
                    Text(LinkStrings.text(.identityWarning)).font(.callout)
                }
                if model.isBusy { LinkProgress() }
                LinkFailure(model: model)
                if draft.existingLinkID != nil {
                    Button(LinkStrings.text(.delete), role: .destructive) { confirmsDelete = true }
                        .disabled(!model.canDelete)
                    if !LinkValidation.canDelete(count: model.links.count, discoveryOn: model.discoveryOn) || model.error?.code == .lastLink {
                        Text(LinkStrings.text(.lastLink)).foregroundStyle(.secondary)
                        if let discoverySettings {
                            Button(LinkStrings.text(.discoverySettings), action: discoverySettings).disabled(model.isBusy)
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
    private func binding(_ keyPath: WritableKeyPath<LinkPreviewDraft, String>) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: keyPath] ?? "" }, set: { model.draft?[keyPath: keyPath] = $0 })
    }
    private func textField(_ label: LinkString, field: LinkField, value: Binding<String>,
                           limit: Int? = nil, required: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LinkStrings.text(label)).font(.headline)
            TextField(LinkStrings.text(label), text: value, axis: .vertical)
                .textFieldStyle(.roundedBorder).accessibilityLabel(LinkStrings.text(label))
            if let limit {
                Text(LinkStrings.counter(LinkValidation.count(value.wrappedValue), limit: limit))
                    .font(.caption).foregroundStyle(.secondary)
                if LinkValidation.count(value.wrappedValue) > limit {
                    Text(String(format: LinkStrings.text(.tooLong), locale: Locale.current, limit)).foregroundStyle(.red)
                }
            }
            if required && LinkValidation.count(value.wrappedValue) == 0 {
                Text(LinkStrings.text(.requiredTitle)).foregroundStyle(.secondary)
            }
            if model.error?.fields.contains(field) == true {
                Text(LinkStrings.text(.invalidField)).foregroundStyle(.red)
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
                TextField(LinkStrings.text(.tags), text: tag).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(LinkStrings.text(.tags))
                Text(LinkStrings.counter(LinkValidation.count(draft.tags[index]), limit: LinkValidation.tagLengthLimit))
                    .font(.caption).foregroundStyle(.secondary)
                if !ProfileValidation.validRequiredText(draft.tags[index], limit: LinkValidation.tagLengthLimit) {
                    Text(LinkStrings.text(.invalidField)).foregroundStyle(.red)
                }
                Button(LinkStrings.text(.removeTag)) { model.draft?.tags.remove(at: index) }
                    .accessibilityLabel(LinkStrings.label(LinkStrings.text(.removeTag), value: draft.tags[index]))
            }
            Text(LinkStrings.counter(draft.tags.count, limit: LinkValidation.tagLimit)).font(.caption).foregroundStyle(.secondary)
            if draft.tags.count > LinkValidation.tagLimit || model.error?.fields.contains(.tags) == true {
                Text(LinkStrings.text(.invalidField)).foregroundStyle(.red)
            }
            Button(LinkStrings.text(.addTag)) { model.draft?.tags.append("") }
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
                    Text(LinkStrings.label(LinkStrings.text(.mainLanguage), value: fresh.mainLanguage))
                    Text(LinkStrings.label(LinkStrings.text(.tags), value: SettingsStrings.joined(fresh.tags)))
                    Text(LinkStrings.label(LinkStrings.text(.description), value: fresh.description))
                    Text(LinkStrings.label(LinkStrings.text(.openingText), value: fresh.openingText))
                }
                Button(LinkStrings.text(.replace), action: model.acceptReplacement).buttonStyle(.borderedProminent)
            }
        }.presentationDragIndicator(.visible)
    }
}

@MainActor
struct LinkPreviewCard: View {
    let draft: LinkPreviewDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.sourceLabel).font(.caption).foregroundStyle(.secondary)
            Text(draft.title).font(.headline)
            if !draft.description.isEmpty { Text(draft.description) }
            if !draft.mainLanguage.isEmpty { Text(draft.mainLanguage).font(.caption) }
            ForEach(Array(draft.tags.enumerated()), id: \.offset) { _, tag in Text(tag).font(.caption) }
            if !draft.openingText.isEmpty { Text(draft.openingText) }
            Text(LinkStrings.text(draft.verified ? .verified : .unverified)).font(.caption)
            Text(LinkStrings.visibility(draft.visibility)).font(.caption)
                .padding(8).background(.teal.opacity(0.1), in: Capsule())
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
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Button(LinkStrings.text(backLabel), action: back).disabled(busy)
                    Spacer()
                    if let save { Button(LinkStrings.text(.save), action: save).disabled(!canSave) }
                }
                Text(LinkStrings.text(title)).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                content
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }.background(Color(uiColor: .systemGroupedBackground)).tint(.teal)
            .navigationBarBackButtonHidden(true)
    }
}

@MainActor
private struct LinkProgress: View {
    var body: some View {
        ProgressView(LinkStrings.text(.loading)).accessibilityLabel(LinkStrings.text(.loading))
    }
}

@MainActor
private struct LinkFailure: View {
    @ObservedObject var model: LinksModel
    var body: some View {
        if let error = model.error {
            VStack(alignment: .leading, spacing: 8) {
                Text(LinkStrings.text(message(error))).foregroundStyle(.red)
                Button(LinkStrings.text(.retry)) { Task { await model.retry() } }.disabled(!model.canRetry)
            }.accessibilityElement(children: .contain)
        } else if model.canRetry {
            Button(LinkStrings.text(.retry)) { Task { await model.retry() } }
        }
    }
    private func message(_ error: LinkActionError) -> LinkString {
        switch error.code {
        case .lastLink: return .lastLink
        case .limitReached: return .linkLimit
        case .sourceUnavailable: return .notAvailable
        case .invalidInput: return .invalidField
        case .unavailable:
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
