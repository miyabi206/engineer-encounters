import Combine
import EncounterBackend
import EncounterBluetooth
import EncounterDomain
import EncounterStorage
import EncounterUI
import Foundation

/// One composition root survives scene creation and keeps one runtime per process.
@MainActor
final class AppComposition: ObservableObject {
    static let shared = AppComposition()
    private let participation: ParticipationFlag
    let account: AccountModel
    let linkAdapter: LinkAdapter
    let sessionHolder: SessionHolder
    let sessionAdapter: SessionAdapter
    let discoverAdapter: DiscoverAdapter
    let qrAdapter: QRAdapter
    let settingsSafetyAdapter: SettingsSafetyAdapter
    let productNavigation = ProductNavigationModel()
    let sampleEncounter: SampleEncounterModel
    private var productSubscriptions: Set<AnyCancellable> = []
    private(set) var sessionServices: SessionBackendServices?
    private let sessionNetwork: SessionNetworkAvailability
    private let linkServicesFactory: (@MainActor (SessionManager) -> (OwnLinkService, GitHubLinksService))?
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
    @Published private(set) var deletionState = AccountSettingsDeletionState.idle
    @Published private(set) var deletionError: ProfileActionError?
    @Published private(set) var checkingDeletionAccount = false
    @Published private(set) var deletionAccountCheckFailed = false
    var deletionSuspended: Bool { deletionState == .pending || deletionState.canRetry }
    private var deletionTask: (epoch: UUID, task: Task<Bool, any Error>)?
    private var deletionCheckTask: (epoch: UUID, task: Task<AccountSettingsAccountState, any Error>)?

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
    let demoSwitch: DemoSwitchSetting
    let demoReveal: DemoRevealController
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
         notificationCenter: (any LocalNotificationCenter)? = nil,
         trialLogURL: URL? = nil,
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
         webAuthenticationRunner: (any GitHubWebAuthenticationRunning)? = nil,
         sessionIsOnline: (@MainActor () -> Bool)? = nil,
         sessionNetwork: SessionNetworkAvailability? = nil,
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
            linkServicesFactory = { sessions in
                (OwnLinkService(client: makeClient(sessions)),
                 GitHubLinksService(client: EdgeFunctionClient(configuration: configuration, transport: transport, sessions: sessions)))
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
            linkServicesFactory = nil
            boundSessionStore = nil
            clientFactory = nil
            client = nil
            account = AccountModel(sessions: nil, service: nil, defaults: defaults, timeZone: timeZone)
        }
        discoverAdapter = DiscoverAdapter(account: account)
        qrAdapter = QRAdapter(account: account, clock: clock)
        sampleEncounter = SampleEncounterModel(store: InstallationSampleDismissalStore(defaults: defaults), isNewUser: true)
        linkAdapter = LinkAdapter(account: account, runner: webAuthenticationRunner ?? SystemGitHubWebAuthenticationRunner())
        settingsSafetyAdapter = SettingsSafetyAdapter(account: account, links: linkAdapter, discover: discoverAdapter)
        sessionHolder = SessionHolder(clock: clock, stops: PendingSessionStopStore(defaults: defaults))
        let sessionNetwork = sessionNetwork ?? SessionNetworkAvailability()
        self.sessionNetwork = sessionNetwork
        sessionAdapter = SessionAdapter(account: account, holder: sessionHolder, clock: clock,
            isOnline: sessionIsOnline ?? { sessionNetwork.isOnline })
        if sessionIsOnline == nil {
            sessionNetwork.onOnline = { [weak sessionAdapter] in
                Task { await sessionAdapter?.foreground() }
            }
        }
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        demoSwitch = DemoSwitchSetting(defaults: defaults)
        demoReveal = DemoRevealController(setting: demoSwitch, center: notificationCenter ?? SystemDemoNotificationCenter(), account: account)
        trialLog = TrialLog(fileURL: trialLogURL)
        trialRecorder = TrialRecorder(log: trialLog)
        presenceApproach = approachSetting.value
        #endif
        isParticipating = participation.isEnabled
        settingsSafetyAdapter.suspendParticipation = { [weak self] in self?.suspendForDeletion() }
        account.isDeletionSuspended = { [weak self] in self?.deletionSuspended == true }
        settingsSafetyAdapter.deleteAccount = { [weak self] epoch, fence in
            guard let self else { throw ProfileActionError(code: .notAuthenticated) }
            return try await self.deleteAccount(epoch: epoch, fence: fence)
        }
        settingsSafetyAdapter.checkAccount = { [weak self] epoch, fence in
            guard let self else { throw ProfileActionError(code: .notAuthenticated) }
            return try await self.checkDeletionAccount(epoch: epoch, fence: fence)
        }
        account.protectedContentDidChange = { [weak discoverAdapter] in discoverAdapter?.protectedContentDidChange() }
        linkAdapter.protectedContentDidChange = { [weak discoverAdapter] in discoverAdapter?.protectedContentDidChange() }
        discoverAdapter.encounterWasDeleted = { [weak productNavigation] _ in
            guard let productNavigation else { return }
            productNavigation.encounterRemoved(in: productNavigation.selection)
        }
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        demoReveal.allowsNotification = { [weak discoverAdapter] in discoverAdapter?.allowsNotification(for: $0) == true }
        discoverAdapter.beforeFeedRead = { [weak self] in
            guard let self, self.demoSwitch.isEnabled else { return }
            await self.runtime?.uploadTask?.value
            try await self.revealDemo()
        }
        demoSwitch.$isEnabled.removeDuplicates().dropFirst().sink { [weak self] enabled in
            if enabled { Task { await self?.demoReveal.switchedOn() } }
            else { self?.demoReveal.switchedOff() }
        }.store(in: &productSubscriptions)
        #endif
        account.prepareForSessionChange = { [weak self] in try await self?.prepareForSessionChange() }
        account.prepareToDiscardSession = { [weak self] in
            self?.discoverAdapter.clearAuthorization()
            self?.qrAdapter.hidePresentation()
            await self?.sessionAdapter.prepareToDiscardSession()
            await self?.qrAdapter.prepareToDiscardSession()
        }
        account.authorizationWillBeDiscarded = { [weak self] in
            self?.discoverAdapter.clearAuthorization()
            self?.qrAdapter.invalidate()
            await self?.sessionAdapter.authorizationWillBeDiscarded()
        }
        account.discoveryWillChange = { [weak self] enabled in try await self?.sessionAdapter.discoveryWillChange(enabled: enabled) }
        account.discoveryDidChange = { [weak self] enabled in await self?.sessionAdapter.discoveryDidChange(enabled: enabled) }
        account.sessionDidChange = { [weak self] force in
            guard let self else { return }
            if self.account.state == .signedOut { self.deletionState = .idle; self.deletionError = nil }
            await self.recreateRuntime(force: force)
        }
        account.canRefreshSession = { [weak self] in
            guard let self, self.storageReady, !self.keychainUnavailable else { return false }
            guard let binding = self.binding else { return true }
            return self.account.state.isSignedIn ? binding.allowsAuthenticatedNetwork : binding.allowsNetwork
        }
        account.bindingGeneration = { binding?.generation }
        qrAdapter.didRedeem = { [weak discoverAdapter] in await discoverAdapter?.foreground() }
        sessionAdapter.$state.map { state in
            if case .active = state { return true }; return false
        }.removeDuplicates().dropFirst().sink { [weak discoverAdapter] _ in
            Task { await discoverAdapter?.foreground() }
        }.store(in: &productSubscriptions)
        sessionAdapter.$failure.sink { [weak discoverAdapter] failure in
            if failure == .accountNotReady { discoverAdapter?.clearAuthorization() }
            if case .prerequisiteMissing(let fields) = failure, fields.contains("discovery") {
                discoverAdapter?.model?.receiveAccess(discoveryOn: false, isAuthorized: true)
            }
        }.store(in: &productSubscriptions)
        qrAdapter.$failure.sink { [weak discoverAdapter] failure in
            if let failure, [.notAuthenticated, .accountNotReady, .declarationRequired].contains(failure.code) {
                discoverAdapter?.clearAuthorization()
            }
            if failure?.code == .prerequisiteMissing, failure?.fields.contains("discovery") == true {
                discoverAdapter?.model?.receiveAccess(discoveryOn: false, isAuthorized: true)
            }
        }.store(in: &productSubscriptions)
        binding?.onReplacement = { [weak self] in
            let runtime = self?.runtime
            let issuer = self?.serverIssuer
            let store = self?.boundSessionStore
            let account = self?.account
            let linkAdapter = self?.linkAdapter
            let sessionAdapter = self?.sessionAdapter
            let storagePreparation = self?.storagePreparationTask
            self?.settingsSafetyAdapter.invalidate()
            self?.discoverAdapter.invalidate()
            self?.qrAdapter.invalidate()
            self?.productNavigation.reset()
            runtime?.suspendForAccountChange()
            return Task {
                await sessionAdapter?.invalidate()
                await linkAdapter?.invalidate()
                await issuer?.invalidate()
                await runtime?.invalidateForAccountChange()
                await account?.drainSessionChange()
                await store?.drain()
                _ = await storagePreparation?.result
            }
        }
        // App.init constructs this even for a Bluetooth background relaunch.
        restorationTask = Task { [weak self] in
            await self?.boundSessionStore?.beforeClearingCredentials { [weak self] in
                self?.discoverAdapter.clearAuthorization()
                self?.qrAdapter.invalidate()
                await self?.sessionAdapter.authorizationWillBeDiscarded()
            }
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
        guard !account.deletionSuspended else { return }
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
        guard participation.isEnabled, !sessionChangeInProgress, !account.deletionSuspended else { return }
        let runtime = makeRuntime()
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        trialRecorder.beginIfNeeded(metadata: trialMetadata)
        #endif
        await runtime.start()
    }

    func requestBluetooth() async throws {
        await waitForRestoration()
        guard !sessionChangeInProgress, !account.deletionSuspended else { throw BackendError.notAuthenticated }
        try await makeRuntime().requestBluetooth()
    }

    func refresh() async {
        await waitForRestoration()
        guard !sessionChangeInProgress, !account.sessionChangeInProgress else { return }
        if account.state == .signedOut, account.sessionCleanupPending {
            await account.refresh()
            return
        }
        guard !account.deletionSuspended else { return }
        if account.state == .signedInPending(nil) || (binding != nil && binding?.preparedOwner == nil && account.state.isSignedIn) {
            storageReady = false
            await account.restore()
        } else if !storageReady || keychainUnavailable { await recreateRuntime(force: true) }
        guard !sessionChangeInProgress, !account.sessionChangeInProgress, !account.deletionSuspended else { return }
        await account.refresh()
        guard !sessionChangeInProgress, !account.sessionChangeInProgress, !account.deletionSuspended else { return }
        await sessionAdapter.foreground()
        guard !sessionChangeInProgress, !account.sessionChangeInProgress, !account.deletionSuspended else { return }
        await runtime?.refresh()
        await discoverAdapter.foreground()
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        trialLog.prune()
        #endif
    }
    #if DEVELOPMENT_BUILD || INTERNAL_BUILD
    func resetTrial() async -> Bool {
        await waitForRestoration()
        guard !sessionChangeInProgress, !account.deletionSuspended else { return false }
        var recorded = false
        let reset = await makeRuntime().resetTrial {
            recorded = self.trialRecorder.resetCompleted(success: true, metadata: self.trialMetadata)
        }
        return reset && recorded
    }
    func selectPresenceApproach(_ approach: PresenceApproach) async {
        await waitForRestoration()
        guard !sessionChangeInProgress, !account.deletionSuspended else { return }
        trialRecorder.selectPresenceApproach(approach)
        approachSetting.value = approach
        presenceApproach = approach
        await runtime?.selectPresenceApproach(approach)
    }

    func retryDiagnostics() async {
        await waitForRestoration()
        guard !sessionChangeInProgress, !account.deletionSuspended else { return }
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
        guard !sessionChangeInProgress, !account.deletionSuspended else { return }
        await makeRuntime().refreshLocalSummary()
    }

    private func suspendForDeletion() {
        guard !deletionSuspended else { return }
        deletionState = .pending
        account.suspendForDeletion()
        isParticipating = false
        runtime?.suspendForAccountChange()
        discoverAdapter.clearAuthorization()
        qrAdapter.hidePresentation()
    }

    func retryAccountDeletion() async {
        _ = try? await deleteAccount(epoch: account.sessionGeneration, fence: account.backendCallFence())
    }

    func checkAccountAndResume() async {
        _ = try? await checkDeletionAccount(epoch: account.sessionGeneration, fence: account.backendCallFence())
    }

    private func deleteAccount(epoch: UUID, fence: BackendCallFence) async throws -> Bool {
        guard fence.isCurrent(), account.sessionGeneration == epoch, account.state.isSignedIn else {
            throw ProfileActionError(code: .notAuthenticated)
        }
        if let deletionTask {
            guard deletionTask.epoch == epoch else { throw ProfileActionError(code: .notAuthenticated) }
            return try await deletionTask.task.value
        }
        guard deletionCheckTask == nil else { throw CancellationError() }
        suspendForDeletion()
        deletionState = .pending; deletionError = nil; deletionAccountCheckFailed = false
        // This task survives a view's cancellation or destruction.
        let task = Task { @MainActor in
            await self.runtime?.stop()
            do {
                let deleted = try await self.settingsSafetyAdapter.performDeletion(epoch, fence: fence)
                guard deleted else { throw ProfileActionError(code: .unavailable) }
                return true
            } catch {
                if fence.isCurrent(), self.account.state.isSignedIn {
                    let failure = error as? ProfileActionError ?? AccountModel.presentationError(error)
                    self.deletionError = failure
                    self.deletionState = failure.code == .prerequisiteMissing && failure.fields.contains("deletion_safety_key")
                        ? .configurationRequired : .failed
                }
                throw error
            }
        }
        deletionTask = (epoch, task)
        defer { deletionTask = nil }
        return try await task.value
    }

    private func checkDeletionAccount(epoch: UUID, fence: BackendCallFence) async throws -> AccountSettingsAccountState {
        guard fence.isCurrent(), account.sessionGeneration == epoch, account.state.isSignedIn else {
            throw ProfileActionError(code: .notAuthenticated)
        }
        if let deletionCheckTask {
            guard deletionCheckTask.epoch == epoch else { throw ProfileActionError(code: .notAuthenticated) }
            return try await deletionCheckTask.task.value
        }
        guard deletionTask == nil, deletionState.canRetry else { throw CancellationError() }
        checkingDeletionAccount = true; deletionError = nil; deletionAccountCheckFailed = false
        let task = Task { @MainActor in
            do {
                let result = try await self.settingsSafetyAdapter.verifyAccount(epoch, fence: fence)
                if case .present = result {
                    guard fence.isCurrent(), self.account.state.isSignedIn else { throw ProfileActionError(code: .notAuthenticated) }
                    self.deletionState = .idle
                    self.account.resumeAfterDeletionFailure()
                    self.settingsSafetyAdapter.publishVerifiedProfile()
                    self.isParticipating = self.participation.isEnabled
                    self.discoverAdapter.invalidate()
                    await self.recreateRuntime(force: true)
                }
                return result
            } catch {
                if fence.isCurrent(), self.account.state.isSignedIn {
                    self.deletionError = error as? ProfileActionError ?? AccountModel.presentationError(error)
                    self.deletionAccountCheckFailed = true
                    self.deletionState = .failed
                }
                throw error
            }
        }
        deletionCheckTask = (epoch, task)
        defer { deletionCheckTask = nil; checkingDeletionAccount = false }
        return try await task.value
    }

    #if DEVELOPMENT_BUILD || INTERNAL_BUILD
    private func revealDemo() async throws {
        let epoch = account.sessionGeneration
        let fence = account.backendCallFence()
        do { try await demoReveal.reveal() }
        catch is CancellationError { throw CancellationError() }
        catch {
            let value = AccountModel.presentationError(error)
            if value.code == .notAuthenticated, fence.isCurrent(), !account.deletionSuspended {
                await account.rejectDeadSession(generation: epoch)
            }
            throw value
        }
    }
    #endif

    private func prepareForSessionChange() async throws {
        // Stop recording/radio before storage cleanup; later callbacks cannot recreate account data.
        let discardingAccount = account.discardingSession || account.state.isSignedIn || account.accountWasDeleted
        if discardingAccount {
            participation.isEnabled = false
            isParticipating = false
        }
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        var trialCleared = true
        if discardingAccount {
            trialRecorder.close()
            trialCleared = trialLog.clear()
            demoSwitch.isEnabled = false
            demoReveal.clear()
            approachSetting.value = .secondExchange
            presenceApproach = .secondExchange
        }
        #endif
        settingsSafetyAdapter.invalidate()
        discoverAdapter.invalidate()
        qrAdapter.invalidate()
        productNavigation.reset()
        sessionChangeInProgress = true
        storageReady = false
        sessionServices = nil
        await sessionHolder.discardPendingStops()
        await sessionAdapter.invalidate()
        await linkAdapter.invalidate()
        binding?.invalidatePreparation()
        try await serializeStoragePreparation { try await self.clearStorageForSessionChange() }
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        if !trialCleared { throw BackendError.storageFailure }
        #endif
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
        guard binding?.isCurrent != false, !account.deletionSuspended || account.state == .signedOut else { return }
        let force = force || keychainUnavailable || (runtime != nil && (!storageReady || runtimeOwner != binding?.preparedOwner))
        sessionChangeInProgress = true
        if let sessions = account.sessions {
            client = clientFactory?(sessions)
            let services = linkServicesFactory?(sessions)
            linkAdapter.configure(own: services?.0, github: services?.1)
        }
        if force, let runtime {
            runtime.suspendForAccountChange()
            await serverIssuer?.invalidate()
            await runtime.invalidateForAccountChange()
            self.runtime = nil
            runtimeStatusSubscription = nil
            serverIssuer = nil
        }
        storageReady = await prepareStorageBinding()
        if storageReady, account.state.isSignedIn, let client, let owner = binding?.preparedOwner,
           owner.accountDigest != nil {
            sessionServices = SessionBackendServices(client: client, account: account, owner: owner)
        } else { sessionServices = nil }
        await sessionAdapter.configure(sessionServices)
        discoverAdapter.configure(sessionServices)
        qrAdapter.configure(sessionServices)
        settingsSafetyAdapter.configure(sessionServices)
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        demoReveal.configure(sessionServices)
        #endif
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
        let sessionHolder = sessionHolder
        let sessionOwner = binding?.preparedOwner
        let runtime = EncounterRuntime(tokenIssuer: issuer, sessionFlag: {
            guard let sessionOwner else { return false }
            return await sessionHolder.isActive(owner: sessionOwner)
        }, approach: approach,
            transportFactory: transportFactory, queueOpener: openQueue, tokenStore: store, clock: clock,
            uploadFactory: uploadFactory, uploadScheduler: uploadScheduler,
            storageIsReady: { [weak self] in
                guard let self, self.storageReady else { return false }
                return self.binding == nil || (self.binding?.isCurrent == true && self.binding?.preparedOwner != nil)
            },
            canCallBackend: { [weak self] in
                guard let self else { return false }
                return !self.account.deletionSuspended && (self.account.state.isSignedIn ? self.account.canRefreshSession() : self.storageReady)
            },
            backendFence: { [weak self] in self?.account.backendCallFence() ?? BackendCallFence { false } })
        #if DEVELOPMENT_BUILD || INTERNAL_BUILD
        let recorder = trialRecorder
        runtime.observeEvents { event in recorder.record(event) }
        runtime.receiptsDidResolve = { [weak self] in try? await self?.revealDemo() }
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
