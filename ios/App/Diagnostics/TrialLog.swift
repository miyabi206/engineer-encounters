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

enum TrialStartReason: String, Codable {
    case reset, participationSwitch, launch
}

struct TrialRecord: Codable, Equatable, Identifiable {
    static let entryLimit = 200
    var id = UUID()
    // The shared source file contains a calendar date only, never a time of day.
    // Retention uses the start of the device-local day, conservatively shortening seven days.
    var ordinal = 1
    var startReason: TrialStartReason = .launch
    var presenceApproachChanged = false
    var creationDate: String
    var metadata: TrialMetadata
    var isOpen = true
    var discoveryElapsedSeconds: TimeInterval?
    var distinctPeerCount = 0
    var exchanges: [TrialExchange] = []
    var evidence: [TrialEvidence] = []
    var droppedExchangeCount = 0
    var droppedEvidenceCount = 0
    var attemptEnds: [TrialAttemptEnd] = []
    let serverConfirmation: TrialMeasurementState = .unavailable

    enum CodingKeys: String, CodingKey {
        case id, ordinal, startReason, presenceApproachChanged, creationDate, metadata, isOpen, discoveryElapsedSeconds, distinctPeerCount
        case exchanges, evidence, droppedExchangeCount, droppedEvidenceCount, attemptEnds, serverConfirmation
    }

    mutating func capEntries() {
        if exchanges.count > Self.entryLimit {
            droppedExchangeCount += exchanges.count - Self.entryLimit
            exchanges.removeLast(exchanges.count - Self.entryLimit)
        }
        if evidence.count > Self.entryLimit {
            droppedEvidenceCount += evidence.count - Self.entryLimit
            evidence.removeLast(evidence.count - Self.entryLimit)
        }
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

    static func calendarDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        dateFormatter(timeZone: timeZone).string(from: date)
    }
    var retentionDate: Date? { Self.dateFormatter().date(from: creationDate) }
    private static func dateFormatter(timeZone: TimeZone = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

extension TrialRecord {
    // Keep the array-based log format; older records have no overflow counters.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        ordinal = try values.decode(Int.self, forKey: .ordinal)
        startReason = try values.decode(TrialStartReason.self, forKey: .startReason)
        presenceApproachChanged = try values.decode(Bool.self, forKey: .presenceApproachChanged)
        creationDate = try values.decode(String.self, forKey: .creationDate)
        metadata = try values.decode(TrialMetadata.self, forKey: .metadata)
        isOpen = try values.decode(Bool.self, forKey: .isOpen)
        discoveryElapsedSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .discoveryElapsedSeconds)
        distinctPeerCount = try values.decode(Int.self, forKey: .distinctPeerCount)
        exchanges = try values.decode([TrialExchange].self, forKey: .exchanges)
        evidence = try values.decode([TrialEvidence].self, forKey: .evidence)
        droppedExchangeCount = try values.decodeIfPresent(Int.self, forKey: .droppedExchangeCount) ?? 0
        droppedEvidenceCount = try values.decodeIfPresent(Int.self, forKey: .droppedEvidenceCount) ?? 0
        attemptEnds = try values.decode([TrialAttemptEnd].self, forKey: .attemptEnds)
    }
}

@MainActor
final class TrialLog: ObservableObject {
    enum State { case loading, ready, failed }
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let recordLimit = 200
    let fileURL: URL
    @Published private(set) var records: [TrialRecord] = []
    @Published private(set) var state: State = .loading
    private let now: () -> Date
    private var didLoad = false
    private(set) var nextOrdinal = 1

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
        didLoad = false
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                records = try JSONDecoder().decode([TrialRecord].self, from: Data(contentsOf: fileURL))
            } else {
                records = []
            }
            nextOrdinal = max(nextOrdinal, (records.map(\.ordinal).max() ?? 0) + 1)
            didLoad = true
            for index in records.indices { records[index].isOpen = false }
            try write()
        } catch { state = .failed }
    }

    func retry() {
        do {
            if !didLoad {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let movedURL = fileURL.appendingPathExtension("unreadable-\(UUID().uuidString)")
                    try FileManager.default.moveItem(at: fileURL, to: movedURL)
                    try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: movedURL.path)
                }
                records = []
                didLoad = true
            }
            try write()
        }
        catch { state = .failed }
    }

    @discardableResult
    func update(_ mutation: (inout [TrialRecord]) -> Void) -> Bool {
        // Never overwrite an unreadable log with a partial fresh one.
        guard didLoad else { return false }
        mutation(&records)
        nextOrdinal = max(nextOrdinal, (records.map(\.ordinal).max() ?? 0) + 1)
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
        do {
            for url in try unreadableFiles() { try FileManager.default.removeItem(at: url) }
            try write()
            didLoad = true
            return true
        }
        catch { state = .failed; return false }
    }

    @discardableResult
    func prune() -> Bool { update { _ in } }

    private func unreadableFiles() throws -> [URL] {
        let directory = fileURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]).filter {
                $0.lastPathComponent.hasPrefix(fileURL.lastPathComponent + ".unreadable-")
            }
    }

    private func write() throws {
        let cutoff = now().addingTimeInterval(-Self.retention)
        records.removeAll { ($0.retentionDate.map { $0 < cutoff }) ?? true }
        // Records are in trial-start order. Preserve the open trial even if it
        // precedes closed ones, and enforce caps before any fallible file I/O.
        var excess = max(0, records.count - Self.recordLimit)
        records.removeAll { record in
            guard excess > 0, !record.isOpen else { return false }
            excess -= 1
            return true
        }
        for index in records.indices { records[index].capEntries() }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        for url in try unreadableFiles() {
            if let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff { try FileManager.default.removeItem(at: url) }
        }
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
