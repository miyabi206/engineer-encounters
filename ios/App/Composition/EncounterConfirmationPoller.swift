import Combine
import EncounterDomain
import EncounterUI
import Foundation

/// One modest timer serves only visible S08/S09. Screens and account/lifecycle fences own its lifetime.
@MainActor
final class EncounterConfirmationPoller {
    static let interval: TimeInterval = 5
    private let clock: any EncounterClock
    private let scheduler: any ReceiptUploadScheduler
    private let load: @MainActor () async -> [EncounterFeedCard]?
    private let calendar: @MainActor () -> Calendar
    private let confirm: @MainActor (QRModel, String) -> Void
    private var jobID: UUID?
    private var job: (any ReceiptUploadCancellation)?
    private var scheduling: Task<Void, Never>?
    private var loading: (id: UUID, task: Task<Void, Never>)?
    private var generation = UUID()
    private var sessionVisible = false
    private var sessionActive = false
    private var sessionWasActive = false
    private weak var qr: QRModel?
    private var qrVisible = false
    private var showingCode = false
    private var showingSegment = true
    private var confirmed = false
    private var knownFeedIDs: Set<String> = []
    private var hasSuccessfulFeed = false
    private var baselineBeforeIssue = false
    private var codeHasBaseline = false
    private var codeGeneration = UUID()
    private var lastReadAt: TimeInterval?
    private var reloadRequested = false
    private var qrSubscriptions: Set<AnyCancellable> = []
    private var foreground = false
    private var authorized = false

    init(clock: any EncounterClock, scheduler: any ReceiptUploadScheduler,
         load: @escaping @MainActor () async -> [EncounterFeedCard]?,
         calendar: @escaping @MainActor () -> Calendar = { Calendar.current },
         confirm: @escaping @MainActor (QRModel, String) -> Void) {
        self.clock = clock; self.scheduler = scheduler; self.load = load
        self.calendar = calendar; self.confirm = confirm
    }

    private var visible: Bool { sessionVisible || (qrVisible && !confirmed) }
    private var canReload: Bool { foreground && authorized && visible }
    private var canPoll: Bool {
        canReload && ((sessionVisible && sessionWasActive) ||
            (qrVisible && showingSegment && showingCode && !confirmed && qr?.isCodeValid == true))
    }

    func receive(foreground: Bool) {
        guard self.foreground != foreground else { return }
        self.foreground = foreground
        pause()
        if canReload { requestReload() }
    }

    func receive(authorized: Bool) {
        guard self.authorized != authorized else { return }
        self.authorized = authorized
        pause()
        if !authorized {
            sessionVisible = false; sessionWasActive = false; sessionActive = false
            qrVisible = false; qr = nil; knownFeedIDs = []; hasSuccessfulFeed = false
            codeHasBaseline = false; qrSubscriptions = []
        } else if canReload { requestReload() }
    }

    func receive(sessionActive: Bool) {
        self.sessionActive = sessionActive
        if sessionVisible, sessionActive { sessionWasActive = true }
        if canPoll { schedule() }
    }

    func openSession() async {
        guard !Task.isCancelled else { return }
        sessionVisible = true; sessionWasActive = sessionActive
        await reload()
        schedule()
    }

    func closeSession() {
        sessionVisible = false; sessionWasActive = false
        if !canPoll { pause() }
    }

    /// Establish the baseline before QRView can issue the first code.
    func openQR(_ model: QRModel) async {
        guard !Task.isCancelled else { return }
        if qr === model, qrVisible {
            await reload()
            schedule()
            return
        }
        qr = model; qrVisible = true; showingCode = model.code != nil
        showingSegment = model.segment == .show; confirmed = model.hasConfirmed
        codeHasBaseline = false; baselineBeforeIssue = false; codeGeneration = UUID()
        qrSubscriptions = []
        await reload()
        guard qr === model, qrVisible else { return }
        model.$isIssuing.dropFirst().sink { [weak self] issuing in
            guard let self, issuing else { return }
            self.baselineBeforeIssue = self.hasSuccessfulFeed
            self.codeHasBaseline = false; self.codeGeneration = UUID()
        }.store(in: &qrSubscriptions)
        model.$code.dropFirst().sink { [weak self] code in
            guard let self else { return }
            let replacing = self.showingCode
            self.showingCode = code != nil
            self.codeGeneration = UUID()
            self.codeHasBaseline = code != nil && self.baselineBeforeIssue
            if replacing { self.requestReload() }
            else { Task { [weak self] in self?.schedule() } }
        }.store(in: &qrSubscriptions)
        model.$segment.dropFirst().sink { [weak self] segment in
            guard let self else { return }
            self.showingSegment = segment == .show
            if self.canPoll { self.requestReload() } else if !self.sessionVisible { self.pause() }
        }.store(in: &qrSubscriptions)
        model.$hasConfirmed.dropFirst().sink { [weak self] confirmed in
            guard let self else { return }
            self.confirmed = confirmed
            if !self.canPoll { self.pause() }
        }.store(in: &qrSubscriptions)
        schedule()
    }

    func closeQR(_ model: QRModel) {
        guard qr === model else { return }
        qrVisible = false; qr = nil; qrSubscriptions = []
        showingCode = false; codeHasBaseline = false; codeGeneration = UUID()
        if !canPoll { pause() }
    }

    /// Upload completion and code replacement/expiry reuse the same bounded read.
    func requestReload() {
        guard canReload else { return }
        job?.cancel(); job = nil; jobID = nil
        scheduling?.cancel(); scheduling = nil
        reloadRequested = true
        schedule()
    }

    private func reload() async {
        guard canReload else { return }
        if let loading { await loading.task.value; return }
        let time = await clock.now()
        guard canReload, !Task.isCancelled else { return }
        if let lastReadAt, time.monotonic < lastReadAt + Self.interval {
            reloadRequested = true
            schedule()
            return
        }
        lastReadAt = time.monotonic; reloadRequested = false
        let id = UUID(), token = generation, codeToken = codeGeneration
        let qrAtStart = qr
        let task = Task { [weak self] in
            guard let self, self.canReload, self.generation == token else { return }
            guard let cards = await self.load(), self.canReload, self.generation == token else { return }
            let known = self.knownFeedIDs
            self.knownFeedIDs.formUnion(cards.map(\.id))
            self.hasSuccessfulFeed = true
            guard let qrAtStart, self.qr === qrAtStart, self.qrVisible,
                  self.codeGeneration == codeToken, self.codeHasBaseline, self.showingCode,
                  self.showingSegment, !self.confirmed, qrAtStart.isCodeValid else { return }
            let now = await self.clock.now()
            guard self.canReload, self.generation == token, self.codeGeneration == codeToken else { return }
            let date = self.calendar().dateComponents([.year, .month, .day], from: now.wall)
            let today = EncounterDay(year: date.year!, month: date.month!, day: date.day!)
            // The feed has no code provenance. A hidden same-day QR returning inside
            // this code's 120 seconds remains indistinguishable from redemption.
            if let new = cards.first(where: { $0.card.kind == .qr && $0.day == today && !known.contains($0.id) }) {
                self.confirmed = true
                self.confirm(qrAtStart, new.id)
            }
        }
        loading = (id, task)
        await task.value
        if loading?.id == id { loading = nil }
    }

    private func schedule() {
        guard canReload, canPoll || reloadRequested, job == nil, scheduling == nil else { return }
        let token = generation
        scheduling = Task { [weak self] in
            guard let self else { return }
            let time = await self.clock.now()
            guard !Task.isCancelled, self.generation == token, self.canReload,
                  self.canPoll || self.reloadRequested else { return }
            self.scheduling = nil
            let id = UUID()
            self.jobID = id
            let delay = self.reloadRequested
                ? max(0, (self.lastReadAt ?? (time.monotonic - Self.interval)) + Self.interval - time.monotonic)
                : Self.interval
            self.job = self.scheduler.schedule(at: time.wall.addingTimeInterval(delay)) { [weak self] in
                guard let self, self.generation == token, self.jobID == id, self.canReload,
                      self.canPoll || self.reloadRequested else { return }
                self.job = nil; self.jobID = nil
                await self.reload()
                self.schedule()
            }
        }
    }

    private func pause() {
        generation = UUID(); reloadRequested = false
        job?.cancel(); job = nil; jobID = nil
        scheduling?.cancel(); scheduling = nil
        loading?.task.cancel(); loading = nil
    }
}
