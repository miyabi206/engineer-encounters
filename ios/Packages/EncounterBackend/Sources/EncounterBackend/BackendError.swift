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
        switch failure.message {
        case "not_authenticated": return .notAuthenticated
        case "account_not_ready": return .accountNotReady
        case "declaration_required": return .declarationRequired
        case "invalid_input": return .invalidInput(fields: fieldNames(failure.details))
        case "prerequisite_missing": return .prerequisiteMissing(fields: fieldNames(failure.details))
        case "rate_limited": return .rateLimited
        case "not_found": return .notFound
        default: return response.statusCode == 401 ? .notAuthenticated : .httpFailure(statusCode: response.statusCode)
        }
    }

    private static func fieldNames(_ detail: String?) -> [String] {
        let knownFields: Set<String> = [
            "age_18", "terms_version", "privacy_version", "time_zone", "display_name", "introduction",
            "contact_detail", "interest", "interests", "interest_ids", "purposes", "link", "enabled",
            "value", "minimum_shared_interests", "field", "level", "covered_until", "receipts", "id",
            "protocol_version", "role", "exchange_nonce", "prior_exchange_nonce", "start", "checkpoint",
            "own_token", "peer_token", "observed_at", "observed_duration", "session_flag", "is_final_evidence",
            "encounter_id"
        ]
        return (detail ?? "").split(separator: ",").compactMap {
            let field = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only contractual field names can enter a printable error.
            return knownFields.contains(field) ? field : nil
        }
    }
}
