import Combine
import EncounterBackend
import EncounterBluetooth
import EncounterDomain
import EncounterStorage
import Foundation

/// One composition root survives scene creation and keeps one runtime per process.
@MainActor
final class AppComposition: ObservableObject {
    static let shared = AppComposition()
    private let participation: ParticipationFlag
    let account: AccountModel
    private var client: RemoteProcedureClient?
    private let clientFactory: (@MainActor (SessionManager) -> RemoteProcedureClient)?
    private var serverTokenStore: any TokenBatchStore
    private let suppliedServerTokenStore: (any TokenBatchStore)?
    private let keychain: any KeychainClient
    private let binding: BackendStorageBinding?
    private let boundSessionStore: BoundSessionStore?
    private let signedOutTokenStore: any TokenBatchStore
    private var serverIssuer: ServerTokenIssuer?
    private var queueOpener: @MainActor () async throws -> any ReceiptQueue
    private let suppliedQueueOpener: (@MainActor () async throws -> any ReceiptQueue)?
    private var storageReady = false
    @Published private var keychainUnavailable = false
    private var storageWasCleared = false
    private var legacyStorageCleared = false
    private let transportFactory: @MainActor () async -> any BluetoothTransport
    private let clock: any EncounterClock
    private let uploadScheduler: any ReceiptUploadScheduler
    private var restorationTask: Task<Void, Never>?
    private var sessionChangeInProgress = false
    private var storagePreparationTask: Task<Void, any Error>?
    static let serverTokenService = "EngineerEncounters.Backend.ServerTokens"
    static func serverTokenService(owner: BackendStorageOwner) -> String {
        serverTokenService + "." + owner.namespace
    }
    @Published private(set) var runtime: EncounterRuntime?
    @Published private(set) var isParticipating = false
    private var runtimeOwner: BackendStorageOwner?
    private var runtimeStatusSubscription: AnyCancellable?
    #if DEVELOPMENT_BUILD || INTERNAL_BUILD
    let trialLog: TrialLog
    let trialRecorder: TrialRecorder
    let demoSwitch = DemoSwitchSetting()
    private let approachSetting = PresenceApproachSetting()
    @Published private(set) var presenceApproach: PresenceApproach
    #endif

    static func backendConfiguration(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> BackendConfiguration? {
        guard let address = info["BackendURL"] as? String,
              let key = info["BackendPublicKey"] as? String,
              !address.contains("$("), !key.contains("$(") else { return nil }
        guard let configuration = BackendConfiguration(address: address, publicClientKey: key),
              BuildKind.isDevelopment || configuration.address.scheme?.lowercased() == "https" else { return nil }
        return configuration
    }

    init(configuration: BackendConfiguration? = AppComposition.backendConfiguration(),
         defaults: UserDefaults = .standard,
         transport: any HTTPTransport = URLSessionHTTPTransport(),
         keychain: any KeychainClient = SystemKeychainClient(),
         sessionStore: (any SessionStore)? = nil,
         serverTokenStore: (any TokenBatchStore)? = nil,
         signedOutTokenStore: (any TokenBatchStore)? = nil,
         queueOpener: (@MainActor () async throws -> any ReceiptQueue)? = nil,
         transportFactory: @escaping @MainActor () async -> any BluetoothTransport = { CoreBluetoothTransport() },
         clock: any EncounterClock = SystemEncounterClock(),
         uploadScheduler: (any ReceiptUploadScheduler)? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         timeZone: @escaping @MainActor () -> String = { TimeZone.current.identifier }) {
        participation = ParticipationFlag(defaults: defaults)
        self.keychain = keychain
        suppliedServerTokenStore = serverTokenStore
        suppliedQueueOpener = queueOpener
        let cleanup = SessionCleanupMarker(defaults: defaults)
        let validConfiguration = configuration.flatMap {
            BuildKind.isDevelopment || $0.address.scheme?.lowercased() == "https" ? $0 : nil
        }
        let binding = validConfiguration.map { BackendStorageBinding(configuration: $0, defaults: defaults, cleanup: cleanup) }
        self.binding = binding
        let previousOwner = binding?.owner
        self.serverTokenStore = serverTokenStore ?? KeychainTokenBatchStore(
            service: previousOwner.map(Self.serverTokenService(owner:)) ?? Self.serverTokenService, client: keychain)
        #if DEVELOPMENT_BUILD
        self.signedOutTokenStore = signedOutTokenStore ?? KeychainTokenBatchStore(
            service: "EngineerEncounters.Development.LocalTestTokens", client: keychain)
        #else
        self.signedOutTokenStore = signedOutTokenStore ?? KeychainTokenBatchStore(client: keychain)
        #endif
        self.queueOpener = queueOpener ?? {
            if let previousOwner { return try await EncounterRuntime.openBoundQueue(namespace: previousOwner.namespace) }
            return try await EncounterRuntime.openDefaultQueue()
        }
        self.transportFactory = transportFactory
        self.clock = clock
        self.uploadScheduler = uploadScheduler ?? ClockReceiptUploadScheduler(clock: clock)
        if let configuration = validConfiguration, let binding {
            let store = BoundSessionStore(sessionStore ?? KeychainSessionStore(backendIdentity: binding.backend, client: keychain),
                                          binding: binding)
            boundSessionStore = store
            let transport = BackendBoundTransport(transport: transport, binding: binding)
            let factory: @MainActor (any SessionStore) -> SessionManager = {
                SessionManager(configuration: configuration, transport: transport, store: $0, now: now)
            }
            let makeClient: @MainActor (SessionManager) -> RemoteProcedureClient = {
                RemoteProcedureClient(configuration: configuration, transport: transport, sessions: $0)
            }
            let sessions = factory(store)
            clientFactory = makeClient
            client = makeClient(sessions)
            account = AccountModel(sessions: sessions, service: OwnAccountService(client: makeClient(sessions)),
                sessionStore: store, sessionFactory: factory,
                serviceFactory: { OwnAccountService(client: makeClient($0)) }, cleanup: cleanup,
                sessionIsCurrent: { binding.isCurrent },
                defaults: defaults, timeZone: timeZone)
        } else {
            boundSessionStore = nil
            clientFactory = nil
            client = nil
            account = AccountModel(sessions: nil, service: nil, defaults: defaults, timeZone: timeZone)
        }
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        trialLog = TrialLog()
        trialRecorder = TrialRecorder(log: trialLog)
        presenceApproach = approachSetting.value
        #endif
        isParticipating = participation.isEnabled
        account.prepareForSessionChange = { [weak self] in try await self?.prepareForSessionChange() }
        account.sessionDidChange = { [weak self] force in await self?.recreateRuntime(force: force) }
        account.canRefreshSession = { [weak self] in
            guard let self, self.storageReady, !self.keychainUnavailable else { return false }
            guard let binding = self.binding else { return true }
            return self.account.state.isSignedIn ? binding.allowsAuthenticatedNetwork : binding.allowsNetwork
        }
        account.bindingGeneration = { binding?.generation }
        binding?.onReplacement = { [weak self] in
            let runtime = self?.runtime
            let issuer = self?.serverIssuer
            let store = self?.boundSessionStore
            let account = self?.account
            let storagePreparation = self?.storagePreparationTask
            runtime?.suspendForAccountChange()
            return Task {
                await issuer?.invalidate()
                await runtime?.invalidateForAccountChange()
                await account?.drainSessionChange()
                await store?.drain()
                _ = await storagePreparation?.result
            }
        }
        // App.init constructs this even for a Bluetooth background relaunch.
        restorationTask = Task { [weak self] in
            await binding?.predecessorDrain?.value
            await self?.account.restore()
        }
    }

    func waitForRestoration() async { await restorationTask?.value }

    var status: EncounterRuntimeStatus {
        var status = runtime?.status ?? EncounterRuntimeStatus()
        status.storageUnavailable = status.storageUnavailable || keychainUnavailable || (binding != nil && (!storageReady || binding?.preparedOwner == nil))
        return status
    }

    func setParticipation(_ enabled: Bool) async {
        participation.isEnabled = enabled
        isParticipating = enabled
        if !enabled {
            await runtime?.stop()
            #if DEVELOPMENT_BUILD || INTERNAL_BUILD
            trialRecorder.close()
            #endif
            return
        }
        await waitForRestoration()
        guard participation.isEnabled, !sessionChangeInProgress else { return }
        let runtime = makeRuntime()
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        trialRecorder.beginIfNeeded(metadata: trialMetadata)
        #endif
        await runtime.start()
    }

    func requestBluetooth() async throws {
        await waitForRestoration()
        guard !sessionChangeInProgress else { throw BackendError.notAuthenticated }
        try await makeRuntime().requestBluetooth()
    }

    func refresh() async {
        await waitForRestoration()
        guard !sessionChangeInProgress, !account.sessionChangeInProgress else { return }
        if account.state == .signedOut, account.sessionCleanupPending {
            await account.refresh()
            return
        }
        if account.state == .signedInPending(nil) || (binding != nil && binding?.preparedOwner == nil && account.state.isSignedIn) {
            storageReady = false
            await account.restore()
        } else if !storageReady || keychainUnavailable { await recreateRuntime(force: true) }
        guard !sessionChangeInProgress, !account.sessionChangeInProgress else { return }
        await account.refresh()
        guard !sessionChangeInProgress, !account.sessionChangeInProgress else { return }
        await runtime?.refresh()
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        trialLog.prune()
        #endif
    }
    #if DEVELOPMENT_BUILD || INTERNAL_BUILD
    func resetTrial() async -> Bool {
        await waitForRestoration()
        guard !sessionChangeInProgress else { return false }
        var recorded = false
        let reset = await makeRuntime().resetTrial {
            recorded = self.trialRecorder.resetCompleted(success: true, metadata: self.trialMetadata)
        }
        return reset && recorded
    }
    func selectPresenceApproach(_ approach: PresenceApproach) async {
        await waitForRestoration()
        guard !sessionChangeInProgress else { return }
        trialRecorder.selectPresenceApproach(approach)
        approachSetting.value = approach
        presenceApproach = approach
        await runtime?.selectPresenceApproach(approach)
    }

    func retryDiagnostics() async {
        await waitForRestoration()
        guard !sessionChangeInProgress else { return }
        if keychainUnavailable || !storageReady { await refresh(); return }
        if trialLog.state == .failed { trialLog.retry() }
        if isParticipating {
            trialRecorder.beginIfNeeded(metadata: trialMetadata, reason: .launch)
            await makeRuntime().start()
        } else { await makeRuntime().refreshLocalSummary() }
    }
    #endif

    func refreshLocalSummary() async {
        await waitForRestoration()
        guard !sessionChangeInProgress else { return }
        await makeRuntime().refreshLocalSummary()
    }

    private func prepareForSessionChange() async throws {
        sessionChangeInProgress = true
        storageReady = false
        binding?.invalidatePreparation()
        try await serializeStoragePreparation { try await self.clearStorageForSessionChange() }
    }

    private func clearStorageForSessionChange() async throws {
        guard binding?.isCurrent != false else { throw BackendError.notAuthenticated }
        sessionChangeInProgress = true
        runtime?.suspendForAccountChange()
        // Drain local saves and queue writes, never an outstanding network request.
        await serverIssuer?.invalidate()
        await runtime?.invalidateForAccountChange()
        runtime = nil
        runtimeStatusSubscription = nil
        serverIssuer = nil
        guard binding?.isCurrent != false else { throw BackendError.notAuthenticated }
        var storageFailed = false
        do { try await serverTokenStore.clear() } catch { storageFailed = true }
        guard binding?.isCurrent != false else { throw BackendError.notAuthenticated }
        do {
            let queue = try await queueOpener()
            try await queue.removeAll()
        } catch { storageFailed = true }
        storageWasCleared = !storageFailed
        storageReady = false
        if storageFailed { throw BackendError.storageFailure }
    }

    private func recreateRuntime(force: Bool) async {
        try? await serializeStoragePreparation { await self.recreatePreparedRuntime(force: force) }
    }

    private func serializeStoragePreparation(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = storagePreparationTask
        let task = Task {
            _ = await previous?.result
            try await operation()
        }
        storagePreparationTask = task
        try await task.value
    }

    private func recreatePreparedRuntime(force: Bool) async {
        guard binding?.isCurrent != false else { return }
        let force = force || keychainUnavailable || (runtime != nil && (!storageReady || runtimeOwner != binding?.preparedOwner))
        sessionChangeInProgress = true
        if let sessions = account.sessions { client = clientFactory?(sessions) }
        if force, let runtime {
            runtime.suspendForAccountChange()
            await serverIssuer?.invalidate()
            await runtime.invalidateForAccountChange()
            self.runtime = nil
            runtimeStatusSubscription = nil
            serverIssuer = nil
        }
        storageReady = await prepareStorageBinding()
        sessionChangeInProgress = false
        guard binding?.isCurrent != false else { return }
        guard force || participation.isEnabled || account.state.isSignedIn else { return }
        let runtime = makeRuntime()
        if participation.isEnabled {
            #if DEVELOPMENT_BUILD || INTERNAL_BUILD
            trialRecorder.beginIfNeeded(metadata: trialMetadata, reason: .launch)
            #endif
            await runtime.start()
        } else if account.state.isSignedIn {
            // Account uploads do not require creating Bluetooth managers.
            await runtime.refresh()
        }
    }

    /// Quarantine legacy and mismatched stores before a manager request or radio preparation.
    private func prepareStorageBinding() async -> Bool {
        guard let binding else { return true }
        guard binding.isCurrent else { return false }
        let epoch = account.sessionGeneration
        let bindingEpoch = binding.generation
        do {
            // A missing legacy item can be deleted successfully while the credential is still locked.
            // Availability must come from reading the current session item, before any quarantine.
            _ = try await keychain.read(service: KeychainSessionStore.service, account: "current")
            keychainUnavailable = false
        } catch {
            keychainUnavailable = true
            return false
        }
        guard binding.isCurrent, epoch == account.sessionGeneration, bindingEpoch == binding.generation else { return false }
        let user: UUID?
        switch account.state {
        case .signedIn(let id), .signedInPending(.some(let id)): user = id
        case .signedInPending(nil): return false // Locked storage is retained, but cannot supply radio tokens.
        default: user = nil
        }
        do {
            try binding.observeAccount(user)
            let preparedGeneration = binding.generation
            let owner = try binding.storageOwner(account: user)
            if !legacyStorageCleared {
                try await KeychainTokenBatchStore(service: Self.serverTokenService, client: keychain).clear()
                try await KeychainTokenBatchStore(client: keychain).clear()
                if suppliedQueueOpener == nil {
                    let legacy = try await EncounterRuntime.openDefaultQueue()
                    try await legacy.removeAll()
                }
                legacyStorageCleared = true
            }
            let previousOwner = binding.owner
            if previousOwner != owner, !storageWasCleared {
                // Preferences may have become readable since launch. Purge the recovered old owner,
                // rather than the legacy opener selected while that owner was unknown.
                let previousTokens: any TokenBatchStore = suppliedServerTokenStore ?? previousOwner.map {
                    KeychainTokenBatchStore(service: Self.serverTokenService(owner: $0), client: keychain)
                } ?? serverTokenStore
                try await previousTokens.clear()
                let queue: any ReceiptQueue
                if suppliedQueueOpener == nil, let previousOwner {
                    queue = try await EncounterRuntime.openBoundQueue(namespace: previousOwner.namespace)
                } else { queue = try await queueOpener() }
                try await queue.removeAll()
            }
            guard binding.isCurrent, epoch == account.sessionGeneration, preparedGeneration == binding.generation else { return false }
            try binding.bind(owner)
            serverTokenStore = suppliedServerTokenStore ?? KeychainTokenBatchStore(
                service: Self.serverTokenService(owner: owner), client: keychain)
            queueOpener = suppliedQueueOpener ?? { try await EncounterRuntime.openBoundQueue(namespace: owner.namespace) }
            storageWasCleared = false
            return true
        } catch {
            if case .keychainStatus = error as? TokenBatchStorageError { keychainUnavailable = true }
            return false
        }
    }

    private func makeRuntime() -> EncounterRuntime {
        if let runtime { return runtime }
        let store: any TokenBatchStore
        let issuer: (any TokenIssuer)?
        if keychainUnavailable {
            store = InMemoryTokenBatchStore()
            issuer = nil
        } else if account.state.isSignedIn, let client {
            if storageReady, let binding, let owner = binding.preparedOwner {
                store = BoundTokenBatchStore(store: serverTokenStore, binding: binding, owner: owner)
            } else { store = InMemoryTokenBatchStore() }
            let server = ServerTokenIssuer(client: client, store: store)
            serverIssuer = server
            issuer = server
        } else {
            store = signedOutTokenStore
            #if DEVELOPMENT_BUILD
            issuer = LocalTestTokenIssuer(store: store)
            #else
            issuer = nil
            #endif
        }
        let uploadFactory: (@MainActor (any ReceiptQueue) -> ReceiptUploader)?
        if storageReady, !account.sessionCleanupPending, account.state.isSignedIn, let client {
            uploadFactory = { ReceiptUploader(client: client, queue: $0) }
        } else { uploadFactory = nil }
        let openQueue: @MainActor () async throws -> any ReceiptQueue
        if keychainUnavailable || (binding != nil && !storageReady) {
            // Unprepared storage cannot prepare a radio or accept nondurable evidence.
            openQueue = { throw BackendError.storageFailure }
        } else if storageReady, let binding, let owner = binding.preparedOwner {
            let opener = queueOpener
            openQueue = { BoundReceiptQueue(queue: try await opener(), binding: binding, owner: owner) }
        } else { openQueue = queueOpener }
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        let approach = presenceApproach
        #else
        let approach = PresenceApproach.secondExchange
        #endif
        let runtime = EncounterRuntime(tokenIssuer: issuer, sessionFlag: { false }, approach: approach,
            transportFactory: transportFactory, queueOpener: openQueue, tokenStore: store, clock: clock,
            uploadFactory: uploadFactory, uploadScheduler: uploadScheduler,
            storageIsReady: { [weak self] in
                guard let self, self.storageReady else { return false }
                return self.binding == nil || (self.binding?.isCurrent == true && self.binding?.preparedOwner != nil)
            },
            canCallBackend: { [weak self] in
                guard let self else { return false }
                return self.account.state.isSignedIn ? self.account.canRefreshSession() : self.storageReady
            },
            backendFence: { [weak self] in self?.account.backendCallFence() ?? BackendCallFence { false } })
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        let recorder = trialRecorder
        runtime.observeEvents { event in recorder.record(event) }
        #endif
        self.runtime = runtime
        runtimeOwner = binding?.preparedOwner
        runtimeStatusSubscription = runtime.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return runtime
    }

    #if DEVELOPMENT_BUILD || INTERNAL_BUILD
    var trialMetadata: TrialMetadata {
        TrialMetadata.capture(approach: presenceApproach, participation: isParticipating,
                              availability: status.radioAvailability)
    }
    #endif
}
