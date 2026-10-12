import Foundation

public struct ReportSettingsTransfer: Decodable, Sendable, Equatable {
    public let reportHour: Int
    public let reportMinute: Int
    public let timeZone: String
    public let notificationsEnabled: Bool
    private enum CodingKeys: String, CodingKey {
        case reportHour = "report_hour", reportMinute = "report_minute", timeZone = "time_zone"
        case notificationsEnabled = "notifications_enabled"
    }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        reportHour = try fields.decode(Int.self, forKey: .reportHour)
        reportMinute = try fields.decode(Int.self, forKey: .reportMinute)
        timeZone = try fields.decode(String.self, forKey: .timeZone)
        notificationsEnabled = try fields.decode(Bool.self, forKey: .notificationsEnabled)
        guard (0...23).contains(reportHour), (0...59).contains(reportMinute) else {
            throw WireValueError.invalidResponse
        }
    }
}

public struct DailyReportTransfer: Decodable, Sendable, Equatable {
    public let reportDay: WireDay?
    public let cards: [FeedCardTransfer]
    public let truncated: Bool
    private enum CodingKeys: String, CodingKey { case reportDay = "report_day", cards, truncated }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        reportDay = try fields.decode(WireDay?.self, forKey: .reportDay)
        cards = try fields.decode([FeedCardTransfer].self, forKey: .cards)
        truncated = try fields.decode(Bool.self, forKey: .truncated)
        guard reportDay != nil || (cards.isEmpty && !truncated) else { throw WireValueError.invalidResponse }
    }
}

/// Stateless scheduling and reveal calls; notification delivery and demo preferences belong to the app.
public struct ReportService: Sendable {
    private let client: RemoteProcedureClient
    public init(client: RemoteProcedureClient) { self.client = client }
    public func getReportSettings() async throws -> ReportSettingsTransfer {
        try await client.call("get_report_settings", parameters: EmptyLinkParameters())
    }
    public func setReportTime(hour: Int32, minute: Int32) async throws -> ReportSettingsTransfer {
        struct Parameters: Encodable, Sendable { let hour: Int32; let minute: Int32 }
        return try await client.call("set_report_time", parameters: Parameters(hour: hour, minute: minute))
    }
    public func setNotificationsEnabled(enabled: Bool) async throws -> ReportSettingsTransfer {
        struct Parameters: Encodable, Sendable { let enabled: Bool }
        return try await client.call("set_notifications_enabled", parameters: Parameters(enabled: enabled))
    }
    public func getDailyReport() async throws -> DailyReportTransfer {
        try await client.call("get_daily_report", parameters: EmptyLinkParameters())
    }
    public func revealAmbientNow() async throws -> EncounterFeedTransfer {
        try await client.call("reveal_ambient_now", parameters: EmptyLinkParameters())
    }
}
