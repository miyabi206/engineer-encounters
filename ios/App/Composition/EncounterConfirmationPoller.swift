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
    private let confirm: @MainActor (QRModel, String) -> Void
    private var jobID: UUID?
    private var job: (any ReceiptUploadCancellation)?
    private var scheduling: Task<Void, Never>?
    private var loading: (id: UUID, task: Task<Void, Never>)?
    private var generation = UUID()
    private var sessionVisible = false
    private weak var qr: QRModel?
    private var qrVisible = false
    private var showingCode = false
    private var showingSegment = true
    private var confirmed = false
    private var knownQRIDs: Set<String>?
    private var qrSubscriptions: Set<AnyCancellable> = []
    private var foreground = false
    private var authorized = false

    init(clock: any EncounterClock, scheduler: any ReceiptUploadScheduler,
         load: @escaping @MainActor () async -> [EncounterFeedCard]?,
         confirm: @escaping @MainActor (QRModel, String) -> Void) {
        self.clock = clock; self.scheduler = scheduler; self.load = load; self.confirm = confirm
    }

    private var visible: Bool { sessionVisible || (qrVisible && !confirmed) }
    private var canReload: Bool { foreground && authorized && visible }
    private var canPoll: Bool { canReload && (sessionVisible || (showingSegment && showingCode && !confirmed)) }

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
            sessionVisible = false; qrVisible = false; qr = nil
            knownQRIDs = nil; qrSubscriptions = []
        } else { schedule() }
    }

    func openSession() async {
        guard !Task.isCancelled else { return }
        sessionVisible = true
        await reload()
        schedule()
    }

    func closeSession() {
        sessionVisible = false
        if !canPoll { pause() }
    }

    /// Establish the baseline before QRView can issue the first code.
    func openQR(_ model: QRModel) async {
        guard !Task.isCancelled else { return }
        qr = model; qrVisible = true; showingCode = model.code != nil
        showingSegment = model.segment == .show; confirmed = model.hasConfirmed
        knownQRIDs = nil
        qrSubscriptions = []
        await reload()
        guard qr === model, qrVisible else { return }
        model.$code.dropFirst().sink { [weak self] code in
            guard let self else { return }
            let replacing = self.showingCode
            self.showingCode = code != nil
            if replacing { self.requestReload() }
            else { self.schedule() }
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
        qrVisible = false; qr = nil; knownQRIDs = nil; qrSubscriptions = []
        showingCode = false
        if !canPoll { pause() }
    }

    /// Upload completion and code replacement/expiry reuse the same bounded read.
    func requestReload() {
        guard canReload else { return }
        job?.cancel(); job = nil; jobID = nil
        scheduling?.cancel(); scheduling = nil
        let token = generation
        Task { [weak self] in
            guard let self, self.generation == token else { return }
            await self.reload()
            self.schedule()
        }
    }

    private func reload() async {
        guard canReload else { return }
        if let loading { await loading.task.value; return }
        let id = UUID(), token = generation
        let qrAtStart = qr
        let task = Task { [weak self] in
            guard let self, self.canReload, self.generation == token else { return }
            guard let cards = await self.load(), self.canReload, self.generation == token else { return }
            guard let qrAtStart, self.qr === qrAtStart, self.qrVisible else { return }
            let ids = Set(cards.filter { $0.card.kind == .qr }.map(\.id))
            if let known = self.knownQRIDs, self.showingSegment, !self.confirmed,
               let new = cards.first(where: { $0.card.kind == .qr && !known.contains($0.id) }) {
                self.confirmed = true
                self.confirm(qrAtStart, new.id)
            }
            self.knownQRIDs = (self.knownQRIDs ?? []).union(ids)
        }
        loading = (id, task)
        await task.value
        if loading?.id == id { loading = nil }
    }

    private func schedule() {
        guard canPoll, job == nil, scheduling == nil else { return }
        let token = generation
        scheduling = Task { [weak self] in
            guard let self else { return }
            let time = await self.clock.now()
            guard !Task.isCancelled, self.generation == token, self.canPoll else { return }
            self.scheduling = nil
            let id = UUID()
            self.jobID = id
            self.job = self.scheduler.schedule(at: time.wall.addingTimeInterval(Self.interval)) { [weak self] in
                guard let self, self.generation == token, self.jobID == id, self.canPoll else { return }
                self.job = nil; self.jobID = nil
                await self.reload()
                self.schedule()
            }
        }
    }

    private func pause() {
        generation = UUID()
        job?.cancel(); job = nil; jobID = nil
        scheduling?.cancel(); scheduling = nil
        loading?.task.cancel(); loading = nil
    }
}
