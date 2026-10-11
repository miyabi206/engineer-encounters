import Combine
import EncounterBluetooth
import EncounterBackend
import EncounterDomain
import EncounterStorage
import Foundation

struct EncounterRuntimeStatus: Sendable, Equatable {
    var radioAvailability: RadioAvailability = .unknown
    var discoveryOn = false
    var pausedForLackOfToken = false
    var storageUnavailable = false
    var pendingReceiptCount: Int?
    var validTokenAvailable = false
}

/// App lifecycle and I/O wiring only; all encounter policy stays in the engine.
@MainActor
final class EncounterRuntime: ObservableObject {
    @Published private(set) var status = EncounterRuntimeStatus()
    private static var receiptQueueTask: Task<SwiftDataReceiptQueue, any Error>?
    private var queue: (any ReceiptQueue)?
    private var engine: EncounterEngine?
    private let tokenStore: any TokenBatchStore
    private let transportFactory: @MainActor () async -> any BluetoothTransport
    private let queueOpener: @MainActor () async throws -> any ReceiptQueue
    private let clock: any EncounterClock
    let tokenIssuer: (any TokenIssuer)?
    private let sessionFlag: @Sendable () async -> Bool
    private let uploadFactory: (@MainActor (any ReceiptQueue) -> ReceiptUploader)?
    private let uploadScheduler: any ReceiptUploadScheduler
    private var uploader: ReceiptUploader?
    private var scheduledUpload: (any ReceiptUploadCancellation)?
    private var uploadGeneration = UUID()
    private var validForAccount = true
    private var engineRunning = false
    private var eventTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var participationOn = false
    private var presenceApproach: PresenceApproach
    private var eventObservers: [UUID: @MainActor (EncounterEngineEvent) -> Void] = [:]
    private var tokenTopUpInFlight = false

    init(tokenIssuer: (any TokenIssuer)?, sessionFlag: @escaping @Sendable () async -> Bool,
         approach: PresenceApproach = .secondExchange,
         transportFactory: @escaping @MainActor () async -> any BluetoothTransport = { CoreBluetoothTransport() },
         queueOpener: @escaping @MainActor () async throws -> any ReceiptQueue = { try await EncounterRuntime.openDefaultQueue() },
         tokenStore: any TokenBatchStore,
         clock: any EncounterClock = SystemEncounterClock(),
         uploadFactory: (@MainActor (any ReceiptQueue) -> ReceiptUploader)? = nil,
         uploadScheduler: (any ReceiptUploadScheduler)? = nil) {
        presenceApproach = approach
        self.transportFactory = transportFactory
        self.queueOpener = queueOpener
        self.tokenStore = tokenStore
        self.clock = clock
        self.tokenIssuer = tokenIssuer
        self.sessionFlag = sessionFlag
        self.uploadFactory = uploadFactory
        self.uploadScheduler = uploadScheduler ?? ClockReceiptUploadScheduler(clock: clock)
    }

    static func openDefaultQueue() async throws -> any ReceiptQueue {
        // Only the production opener shares a task: fakes stay isolated per test.
        if receiptQueueTask == nil {
            receiptQueueTask = Task { try await SwiftDataReceiptQueue.fileBacked() }
        }
        do { return try await receiptQueueTask!.value }
        catch {
            // A failed open created no queue. Allow a later Retry to open it.
            receiptQueueTask = nil
            throw error
        }
    }

    /// Synchronous subscribers share the broadcast without dropping measurements
    /// into a bounded observer buffer while writing a local log.
    @discardableResult
    func observeEvents(_ observer: @escaping @MainActor (EncounterEngineEvent) -> Void) -> UUID {
        let id = UUID()
        eventObservers[id] = observer
        return id
    }

    deinit { eventTask?.cancel() }

    func start() async {
        guard validForAccount else { return }
        participationOn = true
        await serialize {
            guard self.participationOn, self.validForAccount else { return }
            await self.engine?.stop()
            self.engineRunning = false
            guard await self.prepare() else { return }
            await self.replenishTokens()
            guard self.participationOn, self.validForAccount else { return }
            self.engineRunning = true
            await self.engine?.start()
            await self.uploadReceipts()
            await self.updateLocalSummary()
        }
    }

    func stop() async {
        participationOn = false
        await serialize {
            await self.engine?.stop()
            self.engineRunning = false
            self.status.discoveryOn = false
            self.status.pausedForLackOfToken = false
            await self.updateLocalSummary()
        }
    }

    func refresh() async {
        await serialize {
            guard self.validForAccount else { return }
            guard self.participationOn else {
                await self.uploadReceipts()
                await self.updateLocalSummary()
                return
            }
            if self.status.storageUnavailable || !self.engineRunning {
                await self.engine?.stop()
                self.engineRunning = false
                guard await self.prepare() else { return }
                await self.replenishTokens()
                guard self.participationOn, self.validForAccount else { return }
                self.engineRunning = true
                await self.engine?.start()
            } else {
                await self.replenishTokens()
                await self.engine?.refresh()
            }
            await self.uploadReceipts()
            await self.updateLocalSummary()
        }
    }

    /// Prevent queued event work or retry callbacks from touching a subsequent account's queue.
    func suspendForAccountChange() {
        validForAccount = false
        participationOn = false
        uploadGeneration = UUID()
        scheduledUpload?.cancel()
        scheduledUpload = nil
        eventTask?.cancel()
    }

    func invalidateForAccountChange() async {
        suspendForAccountChange()
        await stop()
    }

    #if DEVELOPMENT_BUILD || INTERNAL_BUILD
    func selectPresenceApproach(_ approach: PresenceApproach) async {
        await serialize {
            self.presenceApproach = approach
            await self.engine?.selectPresenceApproach(approach)
        }
    }
    #endif

    func refreshLocalSummary() async {
        await serialize {
            guard self.validForAccount else { return }
            await self.updateLocalSummary()
        }
    }

    #if DEVELOPMENT_BUILD || INTERNAL_BUILD
    func resetTrial(onSuccess: @escaping @MainActor () -> Void = {}) async -> Bool {
        // Serialize reset, verification and restart against other lifecycle actions.
        var success = false
        await serialize {
            guard self.validForAccount, await self.prepareQueue(), let queue = self.queue else { return }
            do {
                self.engineRunning = false
                if let engine = self.engine { await engine.reset() }
                else { try await queue.removeAll() }
                success = try await queue.pending().isEmpty
                self.status.storageUnavailable = false
            } catch {
                success = false
                self.status.storageUnavailable = true
            }
            guard success else { return }
            // Start the recorder's new clock before restarting discovery.
            onSuccess()
            if self.participationOn, await self.prepare(), let engine = self.engine {
                await self.replenishTokens()
                self.engineRunning = true
                await engine.start()
            }
            await self.updateLocalSummary()
        }
        return success
    }
    #endif

    private func serialize(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = operationTask
        let next = Task {
            await previous?.value
            await operation()
        }
        operationTask = next
        await next.value
    }

    private func prepare() async -> Bool {
        guard validForAccount, await prepareQueue(), participationOn, let queue else { return false }
        do {
            _ = try await queue.pending()
            status.storageUnavailable = false
        } catch {
            status.storageUnavailable = true
            return false
        }
        if engine != nil { return true }
        // Do not create either Bluetooth manager until consent and durable storage are ready.
        let transport = await transportFactory()
        guard participationOn, validForAccount else { return false }
        let engine = EncounterEngine(transport: transport, tokenProvider: TokenProvider(store: tokenStore),
                                     receiptQueue: queue, clock: clock, approach: presenceApproach, sessionFlag: sessionFlag)
        self.engine = engine
        eventTask = Task { [weak self, engine] in
            for await event in engine.events {
                guard !Task.isCancelled else { break }
                self?.receive(event)
            }
        }
        return true
    }

    private func prepareQueue() async -> Bool {
        if queue != nil { return true }
        do {
            queue = try await queueOpener()
        } catch {
            status.storageUnavailable = true
            return false
        }
        return queue != nil
    }

    private func replenishTokens() async {
        // A failed Keychain read/write leaves token eligibility to the engine.
        guard validForAccount, let tokenIssuer else { return }
        let time = await clock.now()
        guard validForAccount else { return }
        try? await tokenIssuer.replenish(at: time.wall)
    }

    func receive(_ event: EncounterEngineEvent) {
        guard validForAccount else { return }
        for observer in eventObservers.values { observer(event) }
        switch event {
        case .radioAvailability(let availability): status.radioAvailability = availability
        case .discoveryChanged(let enabled):
            status.discoveryOn = enabled
            if enabled { status.pausedForLackOfToken = false }
        case .participationPausedForLackOfToken:
            status.pausedForLackOfToken = participationOn
            guard participationOn, let tokenIssuer, !tokenTopUpInFlight else {
                Task {
                    await self.serialize {
                        guard self.validForAccount else { return }
                        await self.updateTokenStatus()
                    }
                }
                return
            }
            tokenTopUpInFlight = true
            Task {
                await self.serialize {
                    defer { self.tokenTopUpInFlight = false }
                    guard self.validForAccount, self.participationOn, self.engineRunning else { return }
                    do {
                        let time = await self.clock.now()
                        guard self.validForAccount else { return }
                        try await tokenIssuer.replenish(at: time.wall)
                        await self.engine?.refresh()
                    } catch { /* Retry is explicit after a failed top-up; never loop. */ }
                    await self.updateTokenStatus()
                }
            }
        case .receiptStorageFailed:
            status.storageUnavailable = true
            Task {
                await self.serialize {
                    guard self.status.storageUnavailable else { return }
                    await self.engine?.stop()
                    self.engineRunning = false
                }
            }
        case .exchangeCompleted, .evidenceReached:
            // Keep queue/Keychain reads off the event consumer's path so a
            // burst of measurements is recorded before reset/restart resumes.
            Task {
                await self.serialize {
                    guard self.validForAccount else { return }
                    await self.uploadReceipts()
                    await self.updateLocalSummary()
                }
            }
        default: break
        }
    }

    private func uploadReceipts() async {
        // The factory exists only for a signed-in runtime. Participation may be off.
        guard validForAccount, let uploadFactory, await prepareQueue(), let queue else { return }
        scheduledUpload?.cancel()
        scheduledUpload = nil
        let generation = UUID()
        uploadGeneration = generation
        if uploader == nil { uploader = uploadFactory(queue) }
        do {
            let time = await clock.now()
            guard validForAccount, let uploader else { return }
            let outcome = try await uploader.upload(at: time.wall)
            guard validForAccount, generation == uploadGeneration, let next = outcome.nextAttemptAt else { return }
            scheduledUpload = uploadScheduler.schedule(at: next) { [weak self] in
                guard let self, self.validForAccount, generation == self.uploadGeneration else { return }
                await self.serialize {
                    guard self.validForAccount, generation == self.uploadGeneration else { return }
                    await self.uploadReceipts()
                    await self.updateLocalSummary()
                }
            }
        } catch { /* Nonretryable failures wait for the next explicit trigger. Never log receipt material. */ }
    }

    private func updateLocalSummary() async {
        guard await prepareQueue(), let queue else {
            status.pendingReceiptCount = nil
            return
        }
        do {
            status.pendingReceiptCount = try await queue.pending().count
            status.storageUnavailable = false
        }
        catch {
            status.pendingReceiptCount = nil
            if !engineRunning { status.storageUnavailable = true }
        }
        await updateTokenStatus()
    }

    private func updateTokenStatus() async {
        let time = await clock.now()
        let window = try? await TokenProvider(store: tokenStore).window(at: time.wall)
        status.validTokenAvailable = window != nil
        status.pausedForLackOfToken = participationOn && window == nil
    }
}
