import Foundation
import XCTest
@testable import EncounterUI

final class LinksModelTests: XCTestCase {
    @MainActor
    func testImportOneRepositoryCannotSaveUntilVisibilityChosenAndKeepsEditsOnError() async throws {
        let driver = LinkTestDriver()
        let model = driver.model()
        model.beginAdd()
        XCTAssertEqual(model.route, .add)
        await model.loadConnection()
        XCTAssertEqual(model.connection, .notConnected)
        await model.connectGitHub()
        XCTAssertEqual(model.connection, .connected(handle: "owner"))
        XCTAssertEqual(model.paging.repositories, [driver.repository])
        await model.preview(driver.repository)
        XCTAssertEqual(model.route, .edit)
        XCTAssertNil(model.draft?.visibility)
        XCTAssertFalse(model.canSave)
        let refused = await model.save()
        XCTAssertFalse(refused)
        XCTAssertEqual(driver.saveCalls, 0)
        model.draft?.visibility = .private
        model.draft?.title = "Owner title"
        model.draft?.tags = ["Swift"]
        driver.failure = LinkActionError(code: .unavailable)
        driver.failingOperation = .save
        let failed = await model.save()
        XCTAssertFalse(failed)
        XCTAssertEqual(model.route, .edit)
        XCTAssertEqual(model.draft?.title, "Owner title")
        XCTAssertEqual(model.draft?.tags, ["Swift"])
        XCTAssertEqual(model.draft?.visibility, .private)
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertTrue(model.canRetry)
        driver.failure = nil
        await model.retry()
        XCTAssertEqual(model.route, .list)
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.links.count, 1)
        let link = try XCTUnwrap(model.links.first)
        XCTAssertEqual(link.title, "Owner title")
        XCTAssertEqual(link.sourceLabel, "GitHub")
        XCTAssertTrue(link.verified)
        XCTAssertEqual(link.visibility, .private)
        XCTAssertEqual(driver.saveCalls, 2)
        XCTAssertEqual(driver.changedLinks, [model.links])
    }

    @MainActor
    func testFailedPreviewNeverCreatesEditableFormAndRetryCanImport() async {
        let driver = LinkTestDriver(); let model = driver.model()
        model.beginAdd(); await model.connectGitHub()
        driver.failure = LinkActionError(code: .sourceUnavailable); driver.failingOperation = .preview(driver.repository)
        await model.preview(driver.repository)
        XCTAssertEqual(model.route, .add)
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.error?.code, .sourceUnavailable)
        XCTAssertEqual(driver.saveCalls, 0)
        driver.failure = nil
        await model.retry()
        XCTAssertEqual(model.route, .edit)
        XCTAssertNil(model.draft?.visibility)
    }

    @MainActor
    func testConnectionProgressDuplicateRequestsCancellationFailureAndRetry() async {
        let driver = LinkTestDriver(); let model = driver.model()
        driver.duringAction = { operation in
            if operation == .connect {
                XCTAssertEqual(model.connection, .connecting)
                XCTAssertTrue(model.isBusy)
                model.cancelAdd()
                await model.connectGitHub()
            }
        }
        model.beginAdd()
        driver.failure = CancellationError(); driver.failingOperation = .connect
        await model.connectGitHub()
        XCTAssertEqual(driver.connectCalls, 1)
        XCTAssertEqual(model.connection, .notConnected)
        XCTAssertTrue(model.connectionCancelled)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.route, .add)
        XCTAssertFalse(model.isBusy)
        driver.failure = LinkActionError(code: .unavailable)
        await model.connectGitHub()
        XCTAssertEqual(model.connection, .failed)
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.canRetry)
        driver.failure = nil
        await model.retry()
        XCTAssertEqual(model.connection, .connected(handle: "owner"))
        XCTAssertFalse(model.connectionCancelled)
        XCTAssertEqual(driver.connectCalls, 3)
        XCTAssertEqual(driver.requestedPages, [1])
    }

    @MainActor
    func testRestoredConnectionLoadsPagesAndFailureHidesStaleRepositories() async {
        let driver = LinkTestDriver(); driver.connection = .connected(handle: "owner")
        let second = GitHubRepositoryChoice(repositoryID: "456", repositoryName: "Second", title: "Second title", url: driver.repository.url)
        driver.pages[1] = GitHubRepositoryPage(repositories: [driver.repository], nextPage: 2)
        driver.pages[2] = GitHubRepositoryPage(repositories: [second])
        let model = driver.model(); model.beginAdd(); await model.loadConnection()
        XCTAssertEqual(driver.connectCalls, 0)
        XCTAssertEqual(model.paging.nextPage, 2)
        await model.loadRepositories(page: 2)
        XCTAssertEqual(model.paging.repositories, [second])
        XCTAssertEqual(model.paging.previousPage, 1)
        driver.failure = LinkActionError(code: .unavailable); driver.failingOperation = .repositories(1)
        await model.loadRepositories(page: 1)
        XCTAssertTrue(model.paging.repositories.isEmpty)
        XCTAssertFalse(model.hasLoadedRepositories)
        driver.failure = nil
        await model.retry()
        XCTAssertEqual(model.paging.repositories, [driver.repository])
        XCTAssertEqual(driver.requestedPages, [1, 2, 1, 1])
    }

    @MainActor
    func testRefreshFailureCancelAndConfirmationPreserveAllOwnerEditsUntilAccepted() async {
        let driver = LinkTestDriver(); driver.links = [driver.link()]
        let model = driver.model(); model.beginEdit(driver.links[0])
        model.draft?.title = "Owner title"; model.draft?.description = "Owner description"
        model.draft?.openingText = "Owner opening"; model.draft?.mainLanguage = "Owner language"
        model.draft?.tags = ["Owner tag"]
        model.draft?.visibility = .compatibleOnly
        let edited = model.draft
        driver.failure = LinkActionError(code: .unavailable); driver.failingOperation = .refresh
        await model.refresh()
        XCTAssertEqual(model.draft, edited)
        XCTAssertNil(model.replacement)
        driver.failure = nil
        await model.retry()
        XCTAssertEqual(model.draft, edited)
        XCTAssertEqual(model.replacement, driver.refreshed)
        model.cancelReplacement()
        XCTAssertEqual(model.draft, edited)
        XCTAssertNil(model.replacement)
        await model.refresh()
        model.acceptReplacement()
        XCTAssertEqual(model.draft?.title, "Fresh title")
        XCTAssertEqual(model.draft?.description, "Fresh description")
        XCTAssertEqual(model.draft?.openingText, "Fresh opening")
        XCTAssertEqual(model.draft?.mainLanguage, "Rust")
        XCTAssertEqual(model.draft?.tags, ["Fresh tag"])
        XCTAssertEqual(model.draft?.sourceLabel, "GitHub")
        XCTAssertEqual(model.draft?.visibility, .compatibleOnly)
        XCTAssertEqual(model.draft?.existingLinkID, "first")
        XCTAssertEqual(model.draft?.repositoryID, "123")
        XCTAssertNil(model.replacement)
        XCTAssertTrue(model.hasEdits)
        XCTAssertEqual(driver.updateCalls, 0)
    }

    @MainActor
    func testAcceptedRenamedRepositoryRefreshSavesReplacementAndOwnerEdits() async throws {
        let driver = LinkTestDriver(); driver.links = [driver.link()]
        let model = driver.model(); model.beginEdit(driver.links[0])
        await model.refresh()
        XCTAssertEqual(model.replacement?.url, driver.refreshedURL)
        model.acceptReplacement()
        model.draft?.title = "Edited after refresh"; model.draft?.visibility = .everyoneEligible
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(driver.updateCalls, 0)
        XCTAssertEqual(driver.replacements, [true])
        let request = try XCTUnwrap(driver.savedDrafts.first)
        XCTAssertEqual(request.repositoryID, "123")
        XCTAssertEqual(request.sourceItemID, "123")
        XCTAssertEqual(request.repositoryName, "renamed")
        XCTAssertEqual(request.title, "Edited after refresh")
        XCTAssertEqual(request.description, "Fresh description")
        XCTAssertEqual(request.mainLanguage, "Rust")
        XCTAssertEqual(request.tags, ["Fresh tag"])
        XCTAssertEqual(request.openingText, "Fresh opening")
        XCTAssertTrue(request.replaceExisting)
        XCTAssertEqual(request.visibility, .everyoneEligible)
        XCTAssertEqual(model.links.first?.id, "first")
        XCTAssertEqual(model.links.first?.url, driver.refreshedURL)
    }

    @MainActor
    func testExistingRepositoryRequiresExplicitReplacementConfirmation() async {
        let driver = LinkTestDriver(); let model = driver.model()
        model.beginAdd(); await model.connectGitHub(); await model.preview(driver.repository)
        model.draft?.title = "Edited title"; model.draft?.visibility = .private
        driver.failure = LinkActionError(code: .prerequisiteMissing, details: ["refresh_confirmation"])
        driver.failingOperation = .save
        _ = await model.save()
        XCTAssertEqual(driver.replacements, [false])
        XCTAssertEqual(model.replacement, model.draft)
        XCTAssertFalse(model.canRetry)
        model.cancelReplacement()
        XCTAssertEqual(model.draft?.title, "Edited title")
        _ = await model.save()
        model.acceptReplacement(); driver.failure = nil
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(driver.replacements, [false, false, true])
        XCTAssertEqual(driver.savedDrafts.last?.title, "Edited title")
        XCTAssertEqual(driver.savedDrafts.last?.visibility, .private)
    }

    @MainActor
    func testLostConnectionReturnsToConnectAndRetainsEditor() async {
        let driver = LinkTestDriver(); driver.links = [driver.link()]
        let model = driver.model(); model.beginEdit(driver.links[0]); model.draft?.title = "Keep me"
        driver.failure = LinkActionError(code: .prerequisiteMissing, details: ["github"])
        driver.failingOperation = .refresh
        await model.refresh()
        XCTAssertEqual(model.route, .add)
        XCTAssertEqual(model.connection, .notConnected)
        XCTAssertFalse(model.hasLoadedRepositories)
        XCTAssertEqual(model.draft?.title, "Keep me")
        XCTAssertFalse(model.canRetry)
        driver.failure = nil
        await model.connectGitHub(); model.returnToEditor()
        XCTAssertEqual(model.route, .edit)
        XCTAssertEqual(model.draft?.title, "Keep me")
    }

    @MainActor
    func testStartingAddAfterFailedPageResetsAndReloadsConnectionAndRepositories() async {
        let driver = LinkTestDriver(); driver.connection = .connected(handle: nil)
        let model = driver.model(); model.beginAdd(); await model.loadConnection()
        XCTAssertTrue(model.connection.isConnected)
        XCTAssertNil(model.connection.handle)
        XCTAssertEqual(model.paging.repositories, [driver.repository])
        driver.failure = LinkActionError(code: .prerequisiteMissing, details: ["github_reader"])
        driver.failingOperation = .repositories(2)
        await model.loadRepositories(page: 2)
        XCTAssertTrue(model.error?.requires("github_reader") == true)
        XCTAssertTrue(model.canRetry)
        model.cancelAdd(); model.beginAdd()
        XCTAssertFalse(model.hasLoadedConnection)
        XCTAssertFalse(model.hasLoadedRepositories)
        XCTAssertEqual(model.connection, .notConnected)
        driver.failure = nil; await model.loadConnection()
        XCTAssertEqual(driver.loadedConnections, 2)
        XCTAssertEqual(driver.requestedPages, [1, 2, 1])
        await model.preview(driver.repository)
        XCTAssertEqual(model.draft?.repositoryName, driver.repository.repositoryName)
    }

    @MainActor
    func testFailedDeleteCannotBeRetriedGenericallyAndEditingClearsOperation() async {
        let driver = LinkTestDriver(); driver.links = [driver.link()]
        let model = driver.model(); model.beginEdit(driver.links[0])
        driver.failure = LinkActionError(code: .unavailable); driver.failingOperation = .delete
        _ = await model.deleteConfirmed()
        XCTAssertFalse(model.canRetry)
        driver.failure = nil; model.draft?.title = "New edit"
        XCTAssertNil(model.failedOperation)
        await model.retry(); await model.retry(.delete)
        XCTAssertEqual(driver.deleteCalls, 1)
        XCTAssertEqual(model.links, driver.links)
        driver.failure = LinkActionError(code: .unavailable); driver.failingOperation = .save
        _ = await model.save()
        XCTAssertEqual(model.failedOperation, .save)
        driver.failure = nil
        await model.retry(.refresh)
        XCTAssertEqual(driver.updateCalls, 1)
        await model.retry(.save)
        XCTAssertEqual(driver.updateCalls, 2)
        XCTAssertEqual(driver.deleteCalls, 1)
    }

    @MainActor
    func testRemovingTagChecksIndexAndClearsPendingRetry() async {
        let driver = LinkTestDriver(); driver.links = [driver.link()]
        let model = driver.model(); model.beginEdit(driver.links[0]); model.draft?.tags = ["A", "B"]
        model.removeTag(at: -1); model.removeTag(at: 2)
        XCTAssertEqual(model.draft?.tags, ["A", "B"])
        driver.failure = LinkActionError(code: .unavailable); driver.failingOperation = .save
        _ = await model.save()
        model.removeTag(at: 0)
        XCTAssertNil(model.failedOperation)
        XCTAssertEqual(model.draft?.tags, ["B"])
        model.removeTag(at: 1)
        XCTAssertEqual(model.draft?.tags, ["B"])
    }

    @MainActor
    func testLastLinkCannotBeDeletedWithDiscoveryOnAndFailureRetainsInput() async {
        let driver = LinkTestDriver(); driver.links = [driver.link()]
        let model = driver.model(discoveryOn: true); model.beginEdit(driver.links[0])
        XCTAssertFalse(model.canDelete)
        let refused = await model.deleteConfirmed()
        XCTAssertFalse(refused)
        XCTAssertEqual(driver.deleteCalls, 0)
        model.discoveryOn = false
        XCTAssertTrue(model.canDelete)
        driver.failure = LinkActionError(code: .unavailable); driver.failingOperation = .delete
        model.draft?.title = "Owner edit"
        let failed = await model.deleteConfirmed()
        XCTAssertFalse(failed)
        XCTAssertEqual(model.draft?.title, "Owner edit")
        XCTAssertEqual(model.links, driver.links)
        driver.failure = nil
        XCTAssertFalse(model.canRetry)
        await model.retry()
        XCTAssertEqual(driver.deleteCalls, 1)
        _ = await model.deleteConfirmed()
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertEqual(model.route, .list)
        XCTAssertNil(model.draft)
        XCTAssertEqual(driver.deleteCalls, 2)
    }

    @MainActor
    func testServerLastLinkRejectionOffersGuidanceAndDoesNotRetryDeletion() async {
        let driver = LinkTestDriver(); driver.links = [driver.link()]
        let model = driver.model(); model.beginEdit(driver.links[0])
        driver.failure = LinkActionError(code: .prerequisiteMissing, details: ["link"]); driver.failingOperation = .delete
        _ = await model.deleteConfirmed()
        XCTAssertTrue(model.error?.isLastLink == true)
        XCTAssertFalse(model.canDelete)
        XCTAssertFalse(model.canRetry)
        await model.retry()
        XCTAssertEqual(driver.deleteCalls, 1)
        XCTAssertEqual(model.route, .edit)
        model.draft?.title = "Owner edit"
        XCTAssertFalse(model.canDelete)
        model.discoveryOn = false
        XCTAssertTrue(model.canDelete)
    }

    @MainActor
    func testAtTenLinksAddingAndNewSaveAreDisabledButExistingPrivateLinkCanBeEdited() async {
        let driver = LinkTestDriver()
        driver.links = (0..<10).map { driver.link(id: "\($0)", order: $0) }
        let model = driver.model()
        XCTAssertFalse(model.canAdd)
        model.beginAdd()
        XCTAssertEqual(model.route, .list)
        model.beginEdit(driver.links[0])
        XCTAssertEqual(model.draft?.visibility, .private)
        XCTAssertTrue(model.canSave)
        model.draft?.title = "Updated"
        driver.failure = LinkActionError(code: .invalidInput, fields: [.title]); driver.failingOperation = .save
        _ = await model.save()
        XCTAssertEqual(model.error?.fields, [.title])
        XCTAssertEqual(model.draft?.title, "Updated")
        driver.failure = nil
        await model.retry()
        XCTAssertEqual(model.links.count, 10)
        XCTAssertEqual(model.links.first?.title, "Updated")
        XCTAssertEqual(driver.saveCalls, 0)
        XCTAssertEqual(driver.updateCalls, 2)
    }

    @MainActor
    func testDuplicateWritesAndRouteChangesAreIgnoredDuringSave() async {
        let driver = LinkTestDriver(); driver.links = [driver.link()]
        let model = driver.model(); model.beginEdit(driver.links[0])
        driver.duringAction = { operation in
            guard operation == .save else { return }
            XCTAssertTrue(model.isBusy)
            XCTAssertFalse(model.canSave)
            XCTAssertFalse(model.canDelete)
            model.cancelEditor(); model.beginAdd()
            _ = await model.save()
            _ = await model.deleteConfirmed()
            await model.refresh()
            XCTAssertEqual(model.route, .edit)
        }
        _ = await model.save()
        XCTAssertEqual(driver.updateCalls, 1)
        XCTAssertEqual(driver.deleteCalls, 0)
        XCTAssertEqual(model.route, .list)
    }

    @MainActor
    func testReorderIsConfirmedOnlyOnSuccessAndInvalidIDsNeverWrite() async {
        let driver = LinkTestDriver(); driver.links = [driver.link(), driver.link(id: "second", order: 1)]
        let model = driver.model()
        await model.reorder(ids: ["first", "first"])
        await model.reorder(ids: ["unknown", "second"])
        XCTAssertTrue(driver.reorderCalls.isEmpty)
        driver.failure = LinkActionError(code: .unavailable); driver.failingOperation = .reorder(["second", "first"])
        await model.move("second", offset: -1)
        XCTAssertEqual(model.links.map(\.id), ["first", "second"])
        driver.failure = nil
        await model.retry()
        XCTAssertEqual(model.links.map(\.id), ["second", "first"])
        XCTAssertEqual(driver.reorderCalls, [["second", "first"], ["second", "first"]])
    }

    @MainActor
    func testLoadFailureAndCancellationHideStaleOwnedCardsAndAllowRetry() async {
        let driver = LinkTestDriver(); driver.links = [driver.link()]
        let model = driver.model()
        driver.failure = LinkActionError(code: .unavailable); driver.failingOperation = .loadLinks
        await model.loadLinks()
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertFalse(model.hasLoadedLinks)
        XCTAssertFalse(model.canAdd)
        XCTAssertTrue(driver.changedLinks.isEmpty)
        driver.failure = CancellationError()
        await model.retry()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertFalse(model.hasLoadedLinks)
        driver.failure = nil
        await model.loadLinks()
        XCTAssertEqual(model.links, driver.links)
        XCTAssertTrue(model.hasLoadedLinks)
        XCTAssertTrue(model.canAdd)
    }

    @MainActor
    func testCancelNewReturnsToSourceAndCancelExistingReturnsToList() async {
        let driver = LinkTestDriver(); driver.links = [driver.link()]
        let model = driver.model()
        model.beginEdit(driver.links[0]); model.draft?.title = "Unsaved"
        XCTAssertTrue(model.hasEdits)
        model.cancelEditor()
        XCTAssertEqual(model.route, .list)
        XCTAssertEqual(model.links.first?.title, "Saved title")
        model.beginAdd(); model.selectedSource = .github
        await model.connectGitHub(); await model.preview(driver.repository)
        model.cancelEditor()
        XCTAssertEqual(model.route, .add)
        XCTAssertEqual(model.selectedSource, .github)
        XCTAssertNil(model.draft)
        model.cancelAdd()
        XCTAssertEqual(model.route, .list)
    }

    @MainActor
    func testConfirmedWriteSurvivesTaskCancellation() async {
        let driver = LinkTestDriver(); driver.links = [driver.link()]; driver.cancelSuccessfulWrites = true
        let model = driver.model(); model.beginEdit(driver.links[0]); model.draft?.title = "Confirmed"
        let task = Task { @MainActor in await model.save() }
        let saved = await task.value
        XCTAssertTrue(saved)
        XCTAssertEqual(model.links.first?.title, "Confirmed")
        XCTAssertEqual(model.route, .list)
        XCTAssertNil(model.error)
    }
}

@MainActor
final class LinkTestDriver {
    let url = URL(string: "https://github.com/owner/repository")!
    var repository: GitHubRepositoryChoice { GitHubRepositoryChoice(repositoryID: "123", repositoryName: "repository", title: "Repository", description: "Description", mainLanguage: "Swift", tags: ["swift"], url: url) }
    var links: [OwnLinkState] = []
    var connection: GitHubConnectionState = .notConnected
    var pages: [Int: GitHubRepositoryPage] = [:]
    var failure: (any Error)?
    var failingOperation: LinkOperation?
    var duringAction: (@MainActor (LinkOperation) async -> Void)?
    var saveCalls = 0
    var updateCalls = 0
    var connectCalls = 0
    var deleteCalls = 0
    var requestedPages: [Int] = []
    var reorderCalls: [[String]] = []
    var changedLinks: [[OwnLinkState]] = []
    var cancelSuccessfulWrites = false

    var refreshedURL: URL { URL(string: "https://github.com/owner/renamed")! }
    var replacements: [Bool] = []
    var savedDrafts: [LinkPreviewDraft] = []
    var loadedConnections = 0
    var refreshed: LinkPreviewDraft {
        LinkPreviewDraft(repositoryID: "123", repositoryName: "renamed", source: .github, url: refreshedURL, verified: true,
                         sourceLabel: "GitHub", title: "Fresh title", description: "Fresh description",
                         mainLanguage: "Rust", tags: ["Fresh tag"], openingText: "Fresh opening")
    }
    func link(id: String = "first", order: Int = 0) -> OwnLinkState {
        OwnLinkState(id: id, source: .github, sourceLabel: "GitHub", title: "Saved title",
                     url: url, visibility: .private, verified: true, displayOrder: order, sourceItemID: "123")
    }
    func model(discoveryOn: Bool = false) -> LinksModel {
        LinksModel(actions: actions, links: links, discoveryOn: discoveryOn) { self.changedLinks.append($0) }
    }
    private func check(_ operation: LinkOperation) async throws {
        await duringAction?(operation)
        if let failure, failingOperation == nil || failingOperation == operation { throw failure }
    }
    private func saved(id: String, draft: LinkPreviewDraft, visibility: VisibilityLevel) -> OwnLinkState {
        let order = links.first(where: { $0.id == id })?.displayOrder ?? links.count
        let link = OwnLinkState(id: id, source: draft.source, sourceLabel: draft.sourceLabel, title: draft.title,
                                description: draft.description, mainLanguage: draft.mainLanguage, tags: draft.tags,
                                openingText: draft.openingText, url: draft.url, visibility: visibility,
                                verified: draft.verified, displayOrder: order, sourceItemID: draft.repositoryID,
                                repositoryName: draft.repositoryName)
        links.removeAll { $0.id == id }; links.append(link)
        if cancelSuccessfulWrites { withUnsafeCurrentTask { $0?.cancel() } }
        return link
    }
    var actions: LinkActions {
        LinkActions(loadLinks: {
            try await self.check(.loadLinks); return self.links
        }, loadConnection: {
            self.loadedConnections += 1; try await self.check(.loadConnection); return self.connection
        }, connectGitHub: {
            self.connectCalls += 1; try await self.check(.connect)
            self.connection = .connected(handle: "owner"); return self.connection
        }, listRepositories: { page in
            self.requestedPages.append(page); try await self.check(.repositories(page))
            return self.pages[page] ?? GitHubRepositoryPage(repositories: [self.repository])
        }, previewRepository: { repository in
            try await self.check(.preview(repository))
            return LinkPreviewDraft(repositoryID: repository.repositoryID, repositoryName: repository.repositoryName, source: .github, url: self.url,
                                    verified: true, sourceLabel: "GitHub", title: "Repository")
        }, saveRepository: { draft, visibility, replaceExisting in
            self.replacements.append(replaceExisting); self.savedDrafts.append(draft)
            self.saveCalls += 1; try await self.check(.save)
            return self.saved(id: "first", draft: draft, visibility: visibility)
        }, updateLink: { id, draft, visibility in
            self.updateCalls += 1; try await self.check(.save)
            return self.saved(id: id, draft: draft, visibility: visibility)
        }, deleteLink: { id in
            self.deleteCalls += 1; try await self.check(.delete)
            self.links.removeAll { $0.id == id }; return self.links
        }, reorderLinks: { ids in
            self.reorderCalls.append(ids); try await self.check(.reorder(ids))
            self.links = ids.enumerated().compactMap { index, id in
                guard var link = self.links.first(where: { $0.id == id }) else { return nil }
                link.displayOrder = index; return link
            }
            return self.links
        }, refreshPreview: { _ in
            try await self.check(.refresh); return self.refreshed
        })
    }
}
