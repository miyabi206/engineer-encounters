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
    private let client: RemoteProcedureClient?
    private let serverTokenStore: any TokenBatchStore
    private let signedOutTokenStore: any TokenBatchStore
    private var serverIssuer: ServerTokenIssuer?
    private let queueOpener: @MainActor () async throws -> any ReceiptQueue
    private let transportFactory: @MainActor () async -> any BluetoothTransport
    private let clock: any EncounterClock
    private let uploadScheduler: any ReceiptUploadScheduler
    private var restorationTask: Task<Void, Never>?
    private var sessionChangeInProgress = false
    static let serverTokenService = "EngineerEncounters.Backend.ServerTokens"
    @Published private(set) var runtime: EncounterRuntime?
    @Published private(set) var isParticipating = false
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
        return BackendConfiguration(address: address, publicClientKey: key)
    }

    init(configuration: BackendConfiguration? = AppComposition.backendConfiguration(),
         defaults: UserDefaults = .standard,
         transport: any HTTPTransport = URLSessionHTTPTransport(),
         keychain: any KeychainClient = SystemKeychainClient(),
         sessionStore: (any SessionStore)? = nil,
         serverTokenStore: (any TokenBatchStore)? = nil,
         signedOutTokenStore: (any TokenBatchStore)? = nil,
         queueOpener: @escaping @MainActor () async throws -> any ReceiptQueue = { try await EncounterRuntime.openDefaultQueue() },
         transportFactory: @escaping @MainActor () async -> any BluetoothTransport = { CoreBluetoothTransport() },
         clock: any EncounterClock = SystemEncounterClock(),
         uploadScheduler: (any ReceiptUploadScheduler)? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         timeZone: @escaping @MainActor () -> String = { TimeZone.current.identifier }) {
        participation = ParticipationFlag(defaults: defaults)
        self.serverTokenStore = serverTokenStore ?? KeychainTokenBatchStore(service: Self.serverTokenService, client: keychain)
        #if DEVELOPMENT_BUILD
        self.signedOutTokenStore = signedOutTokenStore ?? KeychainTokenBatchStore(
            service: "EngineerEncounters.Development.LocalTestTokens", client: keychain)
        #else
        self.signedOutTokenStore = signedOutTokenStore ?? KeychainTokenBatchStore(client: keychain)
        #endif
        self.queueOpener = queueOpener
        self.transportFactory = transportFactory
        self.clock = clock
        self.uploadScheduler = uploadScheduler ?? ClockReceiptUploadScheduler(clock: clock)
        if let configuration {
            let sessions = SessionManager(configuration: configuration, transport: transport,
                store: sessionStore ?? KeychainSessionStore(client: keychain), now: now)
            let client = RemoteProcedureClient(configuration: configuration, transport: transport, sessions: sessions)
            self.client = client
            account = AccountModel(sessions: sessions, service: OwnAccountService(client: client), timeZone: timeZone)
        } else {
            client = nil
            account = AccountModel(sessions: nil, service: nil, timeZone: timeZone)
        }
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        trialLog = TrialLog()
        trialRecorder = TrialRecorder(log: trialLog)
        presenceApproach = approachSetting.value
        #endif
        isParticipating = participation.isEnabled
        account.prepareForSessionChange = { [weak self] in try await self?.prepareForSessionChange() }
        account.sessionDidChange = { [weak self] force in await self?.recreateRuntime(force: force) }
        // App.init constructs this even for a Bluetooth background relaunch.
        restorationTask = Task { [weak self] in await self?.account.restore() }
    }

    func waitForRestoration() async { await restorationTask?.value }

    var status: EncounterRuntimeStatus { runtime?.status ?? EncounterRuntimeStatus() }

    func setParticipation(_ enabled: Bool) async {
        participation.isEnabled = enabled
        isParticipating = enabled
        await waitForRestoration()
        guard !sessionChangeInProgress else { return }
        if enabled {
            let runtime = makeRuntime()
            #if DEVELOPMENT_BUILD || INTERNAL_BUILD
            trialRecorder.beginIfNeeded(metadata: trialMetadata)
            #endif
            await runtime.start()
        } else {
            await runtime?.stop()
            #if DEVELOPMENT_BUILD || INTERNAL_BUILD
            trialRecorder.close()
            #endif
        }
    }

    func refresh() async {
        await waitForRestoration()
        await account.refresh()
        guard !sessionChangeInProgress else { return }
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
        runtime?.suspendForAccountChange()
        // Invalidation drains a save before clearing; the old runtime also drains uploads.
        await serverIssuer?.invalidate()
        await runtime?.invalidateForAccountChange()
        runtime = nil
        runtimeStatusSubscription = nil
        serverIssuer = nil
        do {
            try await serverTokenStore.clear()
            let queue = try await queueOpener()
            try await queue.removeAll()
        } catch { throw BackendError.storageFailure }
    }

    private func recreateRuntime(force: Bool) async {
        sessionChangeInProgress = false
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

    private func makeRuntime() -> EncounterRuntime {
        if let runtime { return runtime }
        let store: any TokenBatchStore
        let issuer: (any TokenIssuer)?
        if account.state.isSignedIn, let client {
            store = serverTokenStore
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
        if account.state.isSignedIn, let client {
            uploadFactory = { ReceiptUploader(client: client, queue: $0) }
        } else { uploadFactory = nil }
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        let approach = presenceApproach
        #else
        let approach = PresenceApproach.secondExchange
        #endif
        let runtime = EncounterRuntime(tokenIssuer: issuer, sessionFlag: { false }, approach: approach,
            transportFactory: transportFactory, queueOpener: queueOpener, tokenStore: store, clock: clock,
            uploadFactory: uploadFactory, uploadScheduler: uploadScheduler)
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        let recorder = trialRecorder
        runtime.observeEvents { event in recorder.record(event) }
        #endif
        self.runtime = runtime
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
