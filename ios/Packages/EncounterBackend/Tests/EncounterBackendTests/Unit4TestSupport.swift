import Foundation
@testable import EncounterBackend

let unit4IDString = "abcdefab-cdef-abcd-efab-cdefabcdefab"
let unit4ID = UUID(uuidString: unit4IDString)!
let unit4LinkIDString = "fedcbafe-dcba-fedc-bafe-dcbafedcbafe"
let unit4LinkID = UUID(uuidString: unit4LinkIDString)!
let unit4Code = "0123456789abcdef0123456789abcdef"
let unit4SessionJSON = """
{"session_id":"\(unit4IDString)","starts_at":1800000000,"expires_at":1800007200,"server_time":1800000001}
"""
let unit4VisibleLinkJSON = """
{"link_id":"\(unit4LinkIDString)","source":"github","url":"https://github.com/owner/project",
"title":"Project","description":"Description","main_language":null,"tags":["swift"],
"opening_text":"Read me","verification_state":"unverified"}
"""
let unit4CardJSON = """
{"encounter_id":"\(unit4IDString)","kind":"session","day":"2026-10-12",
"display_name":"Name","introduction":"Intro","contact_detail":"Contact","interests":["swift"],
"purposes":["discovery","collaboration"],"links":[\(unit4VisibleLinkJSON)]}
"""
let unit4ShellJSON = """
{"encounter_id":"\(unit4IDString)","kind":"ambient","day":"2026-10-12","shell":true}
"""
let unit4DetailJSON = String(unit4CardJSON.dropLast()) + """
,"favorite":true,"saved_link_ids":["\(unit4LinkIDString)"]}
"""
let unit4FeedCardJSON = String(unit4CardJSON.dropLast()) + #", "favorite":true,"shared_interest_ids":["swift"]}"#
let unit4FeedJSON = "{\"cards\":[\(unit4FeedCardJSON)],\"truncated\":true}"
let unit4SettingsJSON = #"{"report_hour":21,"report_minute":30,"time_zone":"Asia/Tokyo","notifications_enabled":false}"#
let unit4BlockJSON = "{\"block_id\":\"\(unit4IDString)\",\"placed_day\":\"2026-10-12\"}"

/// Reuses the public service entry points for the request, error and fencing matrices.
enum Unit4Procedure: String, CaseIterable, Sendable {
    case startSession = "start_session", stopSession = "stop_session", getOwnSession = "get_own_session"
    case issueQRCode = "issue_qr_code", cancelQRCode = "cancel_qr_code", redeemQRCode = "redeem_qr_code"
    case getEncounterCard = "get_encounter_card", getEncounterFeed = "get_encounter_feed"
    case listEncounterFavorites = "list_encounter_favorites", setEncounterFavorite = "set_encounter_favorite"
    case saveLink = "save_link", unsaveLink = "unsave_link", listSavedLinks = "list_saved_links"
    case deleteEncounter = "delete_encounter", getReportSettings = "get_report_settings"
    case setReportTime = "set_report_time", setNotificationsEnabled = "set_notifications_enabled"
    case getDailyReport = "get_daily_report", revealAmbientNow = "reveal_ambient_now"
    case blockEncounterPerson = "block_encounter_person", listBlocks = "list_blocks", unblock
    case reportEncounterPerson = "report_encounter_person", deleteOwnAccount = "delete_own_account"

    func invoke(_ client: RemoteProcedureClient) async throws {
        switch self {
        case .startSession: _ = try await EncounterSessionService(client: client).startSession()
        case .stopSession: _ = try await EncounterSessionService(client: client).stopSession()
        case .getOwnSession: _ = try await EncounterSessionService(client: client).getOwnSession()
        case .issueQRCode: _ = try await QRService(client: client).issueQRCode()
        case .cancelQRCode: _ = try await QRService(client: client).cancelQRCode()
        case .redeemQRCode: _ = try await QRService(client: client).redeemQRCode(code: unit4Code)
        case .getEncounterCard: _ = try await EncounterService(client: client).getEncounterCard(encounterID: unit4ID)
        case .getEncounterFeed: _ = try await EncounterService(client: client).getEncounterFeed()
        case .listEncounterFavorites: _ = try await EncounterService(client: client).listEncounterFavorites()
        case .setEncounterFavorite:
            _ = try await EncounterService(client: client).setEncounterFavorite(encounterID: unit4ID, favorite: true)
        case .saveLink: _ = try await EncounterService(client: client).saveLink(encounterID: unit4ID, linkID: unit4LinkID)
        case .unsaveLink: _ = try await EncounterService(client: client).unsaveLink(encounterID: unit4ID, linkID: unit4LinkID)
        case .listSavedLinks: _ = try await EncounterService(client: client).listSavedLinks()
        case .deleteEncounter: _ = try await EncounterService(client: client).deleteEncounter(encounterID: unit4ID)
        case .getReportSettings: _ = try await ReportService(client: client).getReportSettings()
        case .setReportTime: _ = try await ReportService(client: client).setReportTime(hour: 21, minute: 30)
        case .setNotificationsEnabled: _ = try await ReportService(client: client).setNotificationsEnabled(enabled: false)
        case .getDailyReport: _ = try await ReportService(client: client).getDailyReport()
        case .revealAmbientNow: _ = try await ReportService(client: client).revealAmbientNow()
        case .blockEncounterPerson: _ = try await SafetyService(client: client).blockEncounterPerson(encounterID: unit4ID)
        case .listBlocks: _ = try await SafetyService(client: client).listBlocks()
        case .unblock: _ = try await SafetyService(client: client).unblock(blockID: unit4ID)
        case .reportEncounterPerson:
            _ = try await SafetyService(client: client).reportEncounterPerson(encounterID: unit4ID, reason: .spam)
        case .deleteOwnAccount: _ = try await AccountDeletionService(client: client).deleteOwnAccount()
        }
    }

    var requestJSON: String {
        switch self {
        case .getEncounterCard, .deleteEncounter, .blockEncounterPerson:
            return "{\"encounter_id\":\"\(unit4IDString)\"}"
        case .setEncounterFavorite: return "{\"encounter_id\":\"\(unit4IDString)\",\"favorite\":true}"
        case .saveLink, .unsaveLink: return "{\"encounter_id\":\"\(unit4IDString)\",\"link_id\":\"\(unit4LinkIDString)\"}"
        case .redeemQRCode: return "{\"code\":\"\(unit4Code)\"}"
        case .setReportTime: return #"{"hour":21,"minute":30}"#
        case .setNotificationsEnabled: return #"{"enabled":false}"#
        case .unblock: return "{\"block_id\":\"\(unit4IDString)\"}"
        case .reportEncounterPerson: return "{\"encounter_id\":\"\(unit4IDString)\",\"reason\":\"spam\",\"link_id\":null}"
        default: return "{}"
        }
    }

    var responseJSON: String {
        switch self {
        case .startSession, .stopSession, .getOwnSession: return unit4SessionJSON
        case .issueQRCode: return "{\"code\":\"\(unit4Code)\",\"expires_at\":1800000120}"
        case .cancelQRCode: return #"{"cancelled":true}"#
        case .redeemQRCode: return "{\"encounter_id\":\"\(unit4IDString)\"}"
        case .getEncounterCard: return unit4DetailJSON
        case .getEncounterFeed, .listEncounterFavorites, .revealAmbientNow: return unit4FeedJSON
        case .setEncounterFavorite: return requestJSON
        case .saveLink: return String(requestJSON.dropLast()) + #", "saved":true}"#
        case .unsaveLink: return String(requestJSON.dropLast()) + #", "saved":false}"#
        case .listSavedLinks:
            return """
            {"links":[{"encounter_id":"\(unit4IDString)","day":"2026-10-12","kind":"qr",
            "link":\(unit4VisibleLinkJSON)}],"truncated":true}
            """
        case .deleteEncounter, .deleteOwnAccount: return #"{"deleted":true}"#
        case .getReportSettings, .setReportTime, .setNotificationsEnabled: return unit4SettingsJSON
        case .getDailyReport:
            let ambient = unit4FeedCardJSON.replacingOccurrences(of: #""kind":"session""#, with: #""kind":"ambient""#)
            return "{\"report_day\":\"2026-10-12\",\"cards\":[\(ambient)],\"truncated\":true}"
        case .blockEncounterPerson: return unit4BlockJSON
        case .listBlocks: return "{\"blocks\":[\(unit4BlockJSON)],\"truncated\":true}"
        case .unblock: return #"{"unblocked":true}"#
        case .reportEncounterPerson: return "{\"report_id\":\"\(unit4IDString)\",\"status\":\"open\"}"
        }
    }

    var parameterFields: [String] {
        switch self {
        case .getEncounterCard, .deleteEncounter, .blockEncounterPerson: return ["encounter_id"]
        case .setEncounterFavorite: return ["encounter_id", "favorite"]
        case .saveLink, .unsaveLink: return ["encounter_id", "link_id"]
        case .redeemQRCode: return ["code"]
        case .setReportTime: return ["hour", "minute"]
        case .setNotificationsEnabled: return ["enabled"]
        case .unblock: return ["block_id"]
        case .reportEncounterPerson: return ["encounter_id", "reason", "link_id"]
        default: return []
        }
    }

    var requiresReady: Bool {
        [.startSession, .issueQRCode, .redeemQRCode, .getEncounterFeed, .getReportSettings,
         .setReportTime, .setNotificationsEnabled, .getDailyReport, .revealAmbientNow].contains(self)
    }
    var requiresDiscovery: Bool {
        [.startSession, .issueQRCode, .redeemQRCode, .getEncounterFeed, .revealAmbientNow].contains(self)
    }
    var canRateLimit: Bool { [.startSession, .issueQRCode, .redeemQRCode, .reportEncounterPerson].contains(self) }
    var canBeNotFound: Bool {
        [.redeemQRCode, .getEncounterCard, .setEncounterFavorite, .saveLink, .unsaveLink,
         .deleteEncounter, .revealAmbientNow, .blockEncounterPerson, .unblock, .reportEncounterPerson].contains(self)
    }
}
