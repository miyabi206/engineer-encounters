import Combine
import Foundation

@MainActor
public final class QRModel: ObservableObject {
    @Published public private(set) var code: QRCode?
    @Published public private(set) var remainingSeconds = 0
    @Published public private(set) var isIssuing = false
    @Published public private(set) var isRedeeming = false
    @Published public private(set) var error: QRActionError?
    @Published public private(set) var segment = QRSegment.show
    @Published public private(set) var cameraPermission = QRCameraPermission.notDetermined
    @Published public private(set) var hasConfirmed = false
    private let actions: QRActions
    private let navigation: QRNavigationActions
    private let monotonicNow: @MainActor () -> TimeInterval
    private var issuedAt: TimeInterval?
    private var automaticReplacementPending = true
    private var automaticStopReason: QRActionError?
    @Published public private(set) var automaticReplacementStopped = false
    private var ownPayloads: Set<QRPayload> = []
    private var pendingCancellation: QRCode?
    private var failedScan: String?
    private var visible = false
    private var revision = 0

    public init(actions: QRActions, navigation: QRNavigationActions,
                monotonicNow: @escaping @MainActor () -> TimeInterval = { SessionMonotonicClock.now() }) {
        self.actions = actions; self.navigation = navigation; self.monotonicNow = monotonicNow
    }

    private var secondsLeft: Int {
        guard let issuedAt else { return 0 }
        let remaining = max(0, 120 - max(0, monotonicNow() - issuedAt))
        return Int(remaining.rounded(.up))
    }
    public var isCodeValid: Bool { code != nil && secondsLeft > 0 }

    private func receiveError(_ error: Error) {
        let failure = (error as? QRActionError) ?? .network
        self.error = failure
        if failure == .rateLimited { automaticReplacementStopped = true; automaticStopReason = failure }
        if case let .prerequisiteMissing(details) = failure, details.contains("discovery") {
            automaticReplacementStopped = true; automaticStopReason = failure
            navigation.openDiscoveryOff()
        }
    }

    public func cameraFailed() { error = .cameraUnavailable }

    public func appear() async {
        visible = true
        await tick()
    }

    /// Invalidate presentation synchronously. Cleanup continues independently of the view's task.
    public func disappear() {
        visible = false; revision += 1
        let outstanding = code ?? pendingCancellation
        code = nil; issuedAt = nil; remainingSeconds = 0
        automaticReplacementPending = true
        pendingCancellation = outstanding
        if let outstanding {
            Task {
                do {
                    try await actions.cancelCode(outstanding)
                    if pendingCancellation == outstanding { pendingCancellation = nil }
                } catch { /* Retained for the next refresh; there is no displayed stale code. */ }
            }
        }
    }

    public func select(_ segment: QRSegment) {
        self.segment = segment; error = segment == .show ? automaticStopReason : nil; failedScan = nil
    }

    public func receiveCameraPermission(_ value: QRCameraPermission) { cameraPermission = value }

    public func tick() async {
        if let code {
            let remaining = secondsLeft
            if remaining != remainingSeconds { remainingSeconds = remaining }
            if remainingSeconds == 0 {
                self.code = nil; issuedAt = nil; pendingCancellation = code
                automaticReplacementPending = true
                if segment == .show, !isRedeeming {
                    let failure = automaticStopReason ?? .notFound
                    if error != failure { error = failure }
                }
            }
        }
        guard visible, segment == .show, code == nil, !isIssuing, !isRedeeming, !hasConfirmed, automaticReplacementPending,
              !automaticReplacementStopped, error == nil || error == .notFound else { return }
        automaticReplacementPending = false
        await refreshCode()
    }

    public func refreshCode() async {
        guard visible, !isIssuing, !isRedeeming, !hasConfirmed else { return }
        isIssuing = true; error = nil; failedScan = nil; automaticReplacementPending = false
        let requestRevision = revision
        if let code { pendingCancellation = code }
        code = nil; issuedAt = nil; remainingSeconds = 0
        defer { isIssuing = false }
        do {
            if let old = pendingCancellation {
                try await actions.cancelCode(old)
                if pendingCancellation == old { pendingCancellation = nil }
            }
            guard revision == requestRevision else { return }
            let newCode = try await actions.issueCode()
            ownPayloads.insert(newCode.payload)
            guard revision == requestRevision else {
                pendingCancellation = newCode
                do {
                    try await actions.cancelCode(newCode)
                    if pendingCancellation == newCode { pendingCancellation = nil }
                } catch { }
                return
            }
            issuedAt = monotonicNow(); code = newCode
            remainingSeconds = 120; automaticReplacementStopped = false; automaticStopReason = nil
        } catch {
            if revision == requestRevision { receiveError(error) }
        }
    }

    public func scan(_ text: String) async {
        guard visible, segment == .scan, !isRedeeming, !isIssuing, !hasConfirmed, error == nil else { return }
        let payload: QRPayload
        switch QRCodeRules.validate(text, ownPayloads: ownPayloads) {
        case let .failure(failure): error = failure; return
        case let .success(value): payload = value
        }
        isRedeeming = true; failedScan = text
        let requestRevision = revision
        defer { isRedeeming = false }
        do {
            let id = try await actions.redeemCode(payload)
            guard revision == requestRevision else { return }
            receiveConfirmedEncounter(id)
        } catch {
            if revision == requestRevision { receiveError(error) }
        }
    }

    /// The showing participant's host supplies a freshly confirmed encounter id here.
    public func receiveConfirmedEncounter(_ id: String) {
        guard !hasConfirmed else { return }
        hasConfirmed = true; error = nil; failedScan = nil
        navigation.openEncounter(id)
    }

    public func retry() async {
        let previous = error
        error = nil
        if segment == .show { await refreshCode() }
        else if previous == .network, let failedScan { await scan(failedScan) }
        else { failedScan = nil }
    }
}
