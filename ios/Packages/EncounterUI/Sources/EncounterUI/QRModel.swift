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
    private let now: @MainActor () -> Date
    private var ownPayloads: Set<QRPayload> = []
    private var pendingCancellation: QRCode?
    private var failedScan: String?
    private var visible = false
    private var revision = 0

    public init(actions: QRActions, navigation: QRNavigationActions,
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.actions = actions; self.navigation = navigation; self.now = now
    }

    public var currentInstant: Date { now() }

    public func cameraFailed() { error = .cameraUnavailable }

    public func appear() async {
        visible = true
        await tick()
    }

    /// Invalidate presentation synchronously. Cleanup continues independently of the view's task.
    public func disappear() {
        visible = false; revision += 1
        let outstanding = code ?? pendingCancellation
        code = nil; remainingSeconds = 0
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
        self.segment = segment; error = nil; failedScan = nil
    }

    public func receiveCameraPermission(_ value: QRCameraPermission) { cameraPermission = value }

    public func tick() async {
        if let code {
            remainingSeconds = SessionCountdown.seconds(until: code.expiresAt, now: now())
            if QRCodeRules.isExpired(code, now: now()) {
                self.code = nil; pendingCancellation = code
                if segment == .show, !isRedeeming { error = .expired }
            }
        }
        guard visible, segment == .show, code == nil, error == nil || error == .expired else { return }
        await refreshCode()
    }

    public func refreshCode() async {
        guard !isIssuing, !isRedeeming, !hasConfirmed else { return }
        isIssuing = true; error = nil; failedScan = nil
        let requestRevision = revision
        if let code { pendingCancellation = code }
        code = nil; remainingSeconds = 0
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
            guard !QRCodeRules.isExpired(newCode, now: now()) else {
                pendingCancellation = newCode; error = .expired; return
            }
            code = newCode
            remainingSeconds = SessionCountdown.seconds(until: newCode.expiresAt, now: now())
        } catch {
            if revision == requestRevision { self.error = (error as? QRActionError) ?? .network }
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
            if revision == requestRevision { self.error = (error as? QRActionError) ?? .network }
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
