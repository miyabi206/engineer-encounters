#if DEVELOPMENT_BUILD || INTERNAL_BUILD
import Combine
import EncounterDomain
import Foundation

struct TrialMetadata: Codable, Equatable {
    var buildKind: String
    var appVersion: String
    var appBuild: String
    var iOSVersion: String
    var deviceModel: String
    var presenceApproach: String
    var participationEnabled: Bool
    var bluetoothAvailability: String
    var batteryLevel: Float?
}

struct TrialExchange: Codable, Equatable {
    var role: ExchangeRole
    var exchangeDigest: String
    var elapsedSeconds: TimeInterval
}

struct TrialEvidence: Codable, Equatable {
    var role: ExchangeRole
    var exchangeDigest: String
    var elapsedSeconds: TimeInterval
    var observedDurationSeconds: TimeInterval
}

struct TrialAttemptEnd: Codable, Equatable {
    var role: ExchangeRole
    var reason: String
    var elapsedSeconds: TimeInterval
}

enum TrialMeasurementState: String, Codable {
    case pending, missing, recorded, unavailable
}

struct TrialRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    // The shared source file contains a calendar date only, never a time of day.
    // Retention uses the start of that UTC day, conservatively shortening seven days.
    var creationDate: String
    var metadata: TrialMetadata
    var isOpen = true
    var discoveryElapsedSeconds: TimeInterval?
    var distinctPeerCount = 0
    var exchanges: [TrialExchange] = []
    var evidence: [TrialEvidence] = []
    var attemptEnds: [TrialAttemptEnd] = []
    let serverConfirmation: TrialMeasurementState = .unavailable

    enum CodingKeys: String, CodingKey {
        case id, creationDate, metadata, isOpen, discoveryElapsedSeconds, distinctPeerCount
        case exchanges, evidence, attemptEnds, serverConfirmation
    }

    var discoveryState: TrialMeasurementState {
        discoveryElapsedSeconds == nil ? absentState : .recorded
    }
    var exchangeState: TrialMeasurementState { exchanges.isEmpty ? absentState : .recorded }
    var evidenceState: TrialMeasurementState { evidence.isEmpty ? absentState : .recorded }
    // Each role/digest remains separate: one device's evidence is not both receipts.
    func evidenceState(for exchange: TrialExchange) -> TrialMeasurementState {
        evidence.contains { $0.role == exchange.role && $0.exchangeDigest == exchange.exchangeDigest }
            ? .recorded : absentState
    }
    private var absentState: TrialMeasurementState { isOpen ? .pending : .missing }

    static func calendarDate(_ date: Date) -> String { dateFormatter().string(from: date) }
    var retentionDate: Date? { Self.dateFormatter().date(from: creationDate) }
    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

@MainActor
final class TrialLog: ObservableObject {
    enum State { case loading, ready, failed }
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    let fileURL: URL
    @Published private(set) var records: [TrialRecord] = []
    @Published private(set) var state: State = .loading
    private let now: () -> Date
    private var didLoad = false

    init(fileURL: URL? = nil, now: @escaping () -> Date = { Date() }) {
        self.fileURL = fileURL ?? URL.applicationSupportDirectory
            .appending(path: "Diagnostics/trial-log.json")
        self.now = now
        load()
    }

    /// A process relaunch closes incomplete trials; a new continuous-clock origin
    /// must never be used to invent elapsed values for an earlier process.
    func load() {
        state = .loading
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                records = try JSONDecoder().decode([TrialRecord].self, from: Data(contentsOf: fileURL))
            } else {
                records = []
            }
            didLoad = true
            for index in records.indices { records[index].isOpen = false }
            try write()
        } catch { state = .failed }
    }

    func retry() {
        guard didLoad else { load(); return }
        do { try write() }
        catch { state = .failed }
    }

    @discardableResult
    func update(_ mutation: (inout [TrialRecord]) -> Void) -> Bool {
        // Never overwrite an unreadable log with a partial fresh one.
        guard state == .ready else { return false }
        mutation(&records)
        do {
            try write()
            return true
        } catch {
            state = .failed
            return false
        }
    }

    /// Reserved for later sign-out/account deletion integration.
    @discardableResult
    func clear() -> Bool {
        records = []
        do { try write(); return true }
        catch { state = .failed; return false }
    }

    @discardableResult
    func prune() -> Bool { update { _ in } }

    private func write() throws {
        let cutoff = now().addingTimeInterval(-Self.retention)
        records.removeAll { ($0.retentionDate.map { $0 < cutoff }) ?? true }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var directoryURL = directory
        try directoryURL.setResourceValues(excluded)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var protectedFile = fileURL
        try protectedFile.setResourceValues(excluded)
        state = .ready
    }
}
#endif
