#if DEVELOPMENT_BUILD || INTERNAL_BUILD
import EncounterDomain
import Foundation

@MainActor
protocol TrialClock {
    var seconds: TimeInterval { get }
}

@MainActor
struct ContinuousTrialClock: TrialClock {
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now
    var seconds: TimeInterval {
        let duration = origin.duration(to: clock.now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}

/// Owned by the composition root, never by the lifetime of S22.
@MainActor
final class TrialRecorder {
    let log: TrialLog
    private let clock: any TrialClock
    private let now: () -> Date
    private var trialID: UUID?
    private var startSeconds: TimeInterval = 0

    init(log: TrialLog, clock: any TrialClock = ContinuousTrialClock(),
         now: @escaping () -> Date = { Date() }) {
        self.log = log; self.clock = clock; self.now = now
    }

    func beginIfNeeded(metadata: TrialMetadata) {
        guard trialID == nil || !log.records.contains(where: { $0.id == trialID && $0.isOpen }) else { return }
        begin(metadata: metadata)
    }

    @discardableResult
    func resetCompleted(success: Bool, metadata: TrialMetadata) -> Bool {
        guard success else { return false }
        return begin(metadata: metadata)
    }

    func close() {
        guard let trialID else { return }
        log.update { records in
            if let index = records.firstIndex(where: { $0.id == trialID }) { records[index].isOpen = false }
        }
        self.trialID = nil
    }

    @discardableResult
    private func begin(metadata: TrialMetadata) -> Bool {
        let record = TrialRecord(creationDate: TrialRecord.calendarDate(now()), metadata: metadata)
        if log.update({ records in
            for index in records.indices { records[index].isOpen = false }
            records.append(record)
        }) {
            trialID = record.id
            startSeconds = clock.seconds
            return true
        }
        return false
    }

    func record(_ event: EncounterEngineEvent) {
        guard let trialID else { return }
        let elapsed = max(0, clock.seconds - startSeconds)
        switch event {
        case .peerFirstObserved:
            // The engine emits this once per distinct peer between resets/stops.
            // Count that privacy-safe signal without retaining the handle.
            change(trialID) {
                if $0.discoveryElapsedSeconds == nil { $0.discoveryElapsedSeconds = elapsed }
                $0.distinctPeerCount += 1
            }
        case .exchangeCompleted(let role, let digest):
            change(trialID) { $0.exchanges.append(TrialExchange(role: role, exchangeDigest: digest, elapsedSeconds: elapsed)) }
        case .evidenceReached(let role, let digest, let duration):
            change(trialID) {
                $0.evidence.append(TrialEvidence(role: role, exchangeDigest: digest,
                    elapsedSeconds: elapsed, observedDurationSeconds: duration))
            }
        case .attemptEnded(let role, let reason):
            change(trialID) {
                $0.attemptEnds.append(TrialAttemptEnd(role: role, reason: String(describing: reason), elapsedSeconds: elapsed))
                if $0.attemptEnds.count > 50 { $0.attemptEnds.removeFirst($0.attemptEnds.count - 50) }
            }
        default: break
        }
    }

    private func change(_ id: UUID, _ mutation: (inout TrialRecord) -> Void) {
        log.update { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            mutation(&records[index])
        }
    }
}
#endif
