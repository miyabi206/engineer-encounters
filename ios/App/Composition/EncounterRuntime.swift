import Combine
import EncounterBluetooth
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
    private var queue: SwiftDataReceiptQueue?
    private var engine: EncounterEngine?
    #if DEVELOPMENT_BUILD
    private let tokenStore = KeychainTokenBatchStore(service: "EngineerEncounters.Development.LocalTestTokens")
    #else
    private let tokenStore = KeychainTokenBatchStore()
    #endif
    private var eventTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<EncounterEngineEvent>.Continuation] = [:]
    private var participationOn = false
    private var presenceApproach: PresenceApproach
    private var eventObservers: [UUID: @MainActor (EncounterEngineEvent) -> Void] = [:]
    #if DEVELOPMENT_BUILD
    private lazy var issuer = LocalTestTokenIssuer(store: tokenStore)
    #endif

    init(approach: PresenceApproach = .heldConnection) { presenceApproach = approach }

    /// Synchronous subscribers share the broadcast without dropping measurements
    /// into a bounded observer buffer while writing a local log.
    @discardableResult
    func observeEvents(_ observer: @escaping @MainActor (EncounterEngineEvent) -> Void) -> UUID {
        let id = UUID()
        eventObservers[id] = observer
        return id
    }

    deinit {
        eventTask?.cancel()
        for continuation in observers.values { continuation.finish() }
    }

    /// Every observer has its own bounded buffer; only eventTask reads engine.events.
    func events() -> AsyncStream<EncounterEngineEvent> {
        let id = UUID()
        let stream = AsyncStream<EncounterEngineEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        observers[id] = stream.continuation
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers.removeValue(forKey: id) }
        }
        return stream.stream
    }

    func start() async {
        participationOn = true
        await serialize {
            guard self.participationOn, await self.prepare() else { return }
            await self.replenishTokens()
            guard self.participationOn else { return }
            await self.engine?.start()
            await self.updateLocalSummary()
        }
    }

    func stop() async {
        participationOn = false
        await serialize {
            await self.engine?.stop()
            self.status.discoveryOn = false
            self.status.pausedForLackOfToken = false
            await self.updateLocalSummary()
        }
    }

    func refresh() async {
        await serialize {
            guard self.participationOn, !self.status.storageUnavailable else { return }
            await self.replenishTokens()
            await self.engine?.refresh()
            await self.updateLocalSummary()
        }
    }

    func selectPresenceApproach(_ approach: PresenceApproach) async {
        await serialize {
            self.presenceApproach = approach
            await self.engine?.selectPresenceApproach(approach)
        }
    }

    func refreshLocalSummary() async {
        await serialize { await self.updateLocalSummary() }
    }

    func resetTrial(onSuccess: @escaping @MainActor () -> Void = {}) async -> Bool {
        // Serialize reset, verification and restart against other lifecycle actions.
        var success = false
        await serialize {
            guard await self.prepareQueue(), let queue = self.queue else { return }
            do {
                if let engine = self.engine { await engine.reset() }
                else { try await queue.removeAll() }
                success = try await queue.pending().isEmpty
            } catch {
                success = false
            }
            guard success else {
                self.status.storageUnavailable = true
                return
            }
            self.status.storageUnavailable = false
            // Start the recorder's new clock before restarting discovery.
            onSuccess()
            if self.participationOn, let engine = self.engine {
                await self.replenishTokens()
                await engine.start()
            }
            await self.updateLocalSummary()
        }
        return success
    }

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
        if engine != nil { return !status.storageUnavailable }
        guard await prepareQueue(), participationOn, let queue else { return false }
        // Do not create either Bluetooth manager until consent and durable storage are ready.
        let transport = CoreBluetoothTransport()
        let engine = EncounterEngine(transport: transport, tokenProvider: TokenProvider(store: tokenStore),
                                     receiptQueue: queue, approach: presenceApproach, sessionFlag: { false })
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
        // Cache the opening task, including failure: never open a second queue in this process.
        if Self.receiptQueueTask == nil {
            Self.receiptQueueTask = Task { try await SwiftDataReceiptQueue.fileBacked() }
        }
        do {
            queue = try await Self.receiptQueueTask?.value
        } catch {
            status.storageUnavailable = true
            return false
        }
        return queue != nil
    }

    private func replenishTokens() async {
        #if DEVELOPMENT_BUILD
        // A failed Keychain read/write leaves token eligibility to the engine.
        try? await issuer.replenish(at: Date())
        await engine?.refresh()
        #endif
    }

    private func receive(_ event: EncounterEngineEvent) {
        for observer in eventObservers.values { observer(event) }
        for continuation in observers.values { continuation.yield(event) }
        switch event {
        case .radioAvailability(let availability): status.radioAvailability = availability
        case .discoveryChanged(let enabled):
            status.discoveryOn = enabled
            if enabled { status.pausedForLackOfToken = false }
        case .participationPausedForLackOfToken:
            status.pausedForLackOfToken = participationOn
            Task { await self.updateTokenStatus() }
        case .receiptStorageFailed:
            status.storageUnavailable = true
            Task {
                guard self.status.storageUnavailable else { return }
                await self.engine?.stop()
            }
        case .exchangeCompleted, .evidenceReached:
            // Keep queue/Keychain reads off the event consumer's path so a
            // burst of measurements is recorded before reset/restart resumes.
            Task { await self.refreshLocalSummary() }
        default: break
        }
    }

    private func updateLocalSummary() async {
        guard await prepareQueue(), let queue else {
            status.pendingReceiptCount = nil
            return
        }
        do { status.pendingReceiptCount = try await queue.pending().count }
        catch {
            status.pendingReceiptCount = nil
            status.storageUnavailable = true
        }
        await updateTokenStatus()
    }

    private func updateTokenStatus() async {
        let window = try? await TokenProvider(store: tokenStore).window(at: Date())
        status.validTokenAvailable = window != nil
        status.pausedForLackOfToken = participationOn && window == nil
    }
}
