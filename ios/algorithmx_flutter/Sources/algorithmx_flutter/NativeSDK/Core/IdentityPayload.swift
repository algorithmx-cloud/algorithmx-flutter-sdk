import Foundation
import CoreFoundation

struct IdentityPayload {
    static let identifierFields = ["email": "Email", "phone": "Phone", "userName": "UserName"]
    static let textFields: Set<String> = ["firstName", "lastName", "gender", "dateOfBirth", "registeredAt"]
    static let consentFields: Set<String> = ["emailOptIn", "smsOptIn", "pushOptIn", "gdprAccepted", "whatsAppOptIn"]

    static func identifiers(userId: String, attributes: [String: Any]?) throws -> [String: String] {
        guard !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("userId must not be empty") }
        var result = ["ExternalId": userId]
        for (field, type) in identifierFields {
            if let value = attributes?[field] {
                guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalid("\(field) must be non-empty text")
                }
                result[type] = text
            }
        }
        return result
    }

    static func profile(_ attributes: [String: Any]?) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for (field, value) in attributes ?? [:] {
            if textFields.contains(field) {
                guard value is String else { throw invalid("\(field) must be text (dates use ISO 8601)") }
                result[field] = value
            } else if consentFields.contains(field) {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw invalid("\(field) must be a boolean")
                }
                result[field] = value
            } else if identifierFields[field] == nil {
                throw invalid("Unsupported profile field: \(field). Use trackEvent for custom event data.")
            }
        }
        return result
    }

    private static func invalid(_ description: String) -> NSError {
        NSError(domain: "AlgorithmX", code: -1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
