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
    #if DEVELOPMENT_BUILD
    private lazy var issuer = LocalTestTokenIssuer(store: tokenStore)
    #endif

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
            await self.updateTokenStatus()
        }
    }

    func stop() async {
        participationOn = false
        await serialize {
            await self.engine?.stop()
            self.status.discoveryOn = false
            self.status.pausedForLackOfToken = false
        }
    }

    func refresh() async {
        await serialize {
            guard self.participationOn, !self.status.storageUnavailable else { return }
            await self.replenishTokens()
            await self.engine?.refresh()
            await self.updateTokenStatus()
        }
    }

    func selectPresenceApproach(_ approach: PresenceApproach) async {
        await serialize { await self.engine?.selectPresenceApproach(approach) }
    }

    func resetTrial() async -> Bool {
        // Serialize reset, verification and restart against other lifecycle actions.
        var success = false
        await serialize {
            guard let engine = self.engine, let queue = self.queue else { return }
            await engine.reset()
            do {
                success = try await queue.pending().isEmpty
            } catch {
                success = false
            }
            guard success else {
                self.status.storageUnavailable = true
                return
            }
            self.status.storageUnavailable = false
            if self.participationOn {
                await self.replenishTokens()
                await engine.start()
                await self.updateTokenStatus()
            }
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
        guard participationOn, let queue else { return false }
        // Do not create either Bluetooth manager until consent and durable storage are ready.
        let transport = CoreBluetoothTransport()
        let engine = EncounterEngine(transport: transport, tokenProvider: TokenProvider(store: tokenStore),
                                     receiptQueue: queue, sessionFlag: { false })
        self.engine = engine
        eventTask = Task { [weak self, engine] in
            for await event in engine.events {
                guard !Task.isCancelled else { break }
                await self?.receive(event)
            }
        }
        return true
    }

    private func replenishTokens() async {
        #if DEVELOPMENT_BUILD
        // A failed Keychain read/write leaves token eligibility to the engine.
        try? await issuer.replenish(at: Date())
        await engine?.refresh()
        #endif
    }

    private func receive(_ event: EncounterEngineEvent) async {
        switch event {
        case .radioAvailability(let availability): status.radioAvailability = availability
        case .discoveryChanged(let enabled):
            status.discoveryOn = enabled
            if enabled { status.pausedForLackOfToken = false }
        case .participationPausedForLackOfToken: await updateTokenStatus()
        case .receiptStorageFailed:
            status.storageUnavailable = true
            await engine?.stop()
        default: break
        }
        for continuation in observers.values { continuation.yield(event) }
    }

    private func updateTokenStatus() async {
        let window = try? await TokenProvider(store: tokenStore).window(at: Date())
        status.pausedForLackOfToken = participationOn && window == nil
    }
}
