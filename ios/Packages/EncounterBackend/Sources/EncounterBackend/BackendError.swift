import Foundation

/// Stable contract failures and sanitized client failures; never contains response bytes.
public enum BackendError: Error, Equatable, Sendable {
    case notAuthenticated
    case accountNotReady
    case declarationRequired
    case invalidInput(fields: [String])
    case prerequisiteMissing(fields: [String])
    case rateLimited
    case notFound
    case invalidRequest
    case invalidResponse
    case transportFailure
    case storageFailure
    case httpFailure(statusCode: Int)

    static func response(_ response: HTTPResponse) -> BackendError {
        struct Failure: Decodable { let message: String; let details: String? }
        guard let failure = try? JSONDecoder().decode(Failure.self, from: response.data) else {
            return response.statusCode == 401 ? .notAuthenticated : .httpFailure(statusCode: response.statusCode)
        }
        return applicationCode(failure.message, fields: fieldNames(failure.details), status: response.statusCode)
    }

    /// Data API coercion runs before SQL validation; recover only contractual parameter names.
    static func response(_ response: HTTPResponse, procedure: String, parameters: Data) -> BackendError {
        struct Failure: Decodable { let code: String }
        guard response.statusCode == 400,
              let failure = try? JSONDecoder().decode(Failure.self, from: response.data),
              ["22P02", "22003", "42804"].contains(failure.code),
              let object = try? JSONSerialization.jsonObject(with: parameters) as? [String: Any] else {
            return Self.response(response)
        }
        let signature: [(String, ParameterType)]
        switch procedure {
        case "update_own_link":
            signature = [("link_id", .uuid), ("title", .text), ("description", .text),
                         ("main_language", .nullableText), ("tags", .texts), ("opening_text", .text), ("visibility", .text)]
        case "delete_own_link": signature = [("link_id", .uuid)]
        case "reorder_own_links": signature = [("link_ids", .uuids)]
        default: return Self.response(response)
        }
        let fields = signature.compactMap { name, type in type.accepts(object[name]) ? nil : name }
        return fields.isEmpty ? Self.response(response) : .invalidInput(fields: fields)
    }

    private enum ParameterType {
        case uuid, uuids, text, nullableText, texts
        func accepts(_ value: Any?) -> Bool {
            switch self {
            case .uuid: return (value as? String).flatMap(UUID.init(uuidString:)) != nil
            case .uuids:
                guard let values = value as? [String] else { return false }
                return values.allSatisfy { UUID(uuidString: $0) != nil }
            case .text: return value is String
            case .nullableText: return value is String || value is NSNull
            case .texts: return value is [String]
            }
        }
    }

    static func edgeResponse(_ response: HTTPResponse) -> BackendError {
        struct Failure: Decodable {
            struct Detail: Decodable { let code: String; let details: [String] }
            let error: Detail
        }
        guard let failure = try? JSONDecoder().decode(Failure.self, from: response.data) else {
            switch response.statusCode {
            case 401: return .notAuthenticated
            case 429: return .rateLimited
            default: return .httpFailure(statusCode: response.statusCode)
            }
        }
        return applicationCode(failure.error.code, fields: failure.error.details.filter(knownFields.contains),
                               status: response.statusCode)
    }

    private static func applicationCode(_ code: String, fields: [String], status: Int) -> BackendError {
        switch code {
        case "not_authenticated": return .notAuthenticated
        case "account_not_ready": return .accountNotReady
        case "declaration_required": return .declarationRequired
        case "invalid_input": return .invalidInput(fields: fields)
        case "prerequisite_missing": return .prerequisiteMissing(fields: fields)
        case "rate_limited": return .rateLimited
        case "not_found": return .notFound
        default: return status == 401 ? .notAuthenticated : .httpFailure(statusCode: status)
        }
    }

    static let knownFields: Set<String> = [
        "age_18", "terms_version", "privacy_version", "time_zone", "display_name", "introduction",
        "contact_detail", "interest", "interests", "interest_ids", "purposes", "link", "enabled",
        "value", "minimum_shared_interests", "field", "level", "covered_until", "receipts", "id",
        "protocol_version", "role", "exchange_nonce", "prior_exchange_nonce", "start", "checkpoint",
        "own_token", "peer_token", "observed_at", "observed_duration", "session_flag", "is_final_evidence",
        "encounter_id", "link_id", "link_ids", "title", "description", "main_language", "tags",
        "opening_text", "visibility", "refresh_confirmation", "method", "body", "action", "page",
        "repository_id", "repository_name", "replace_existing", "github_reader", "github",
        "discovery", "code", "favorite", "hour", "minute", "block_id", "reason", "deletion_safety_key"
    ]

    private static func fieldNames(_ detail: String?) -> [String] {
        return (detail ?? "").split(separator: ",").compactMap {
            let field = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only contractual field names can enter a printable error.
            return knownFields.contains(field) ? field : nil
        }
    }
}
