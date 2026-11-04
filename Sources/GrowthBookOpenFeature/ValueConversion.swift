import Foundation
import GrowthBook
import OpenFeature

/// Strict conversions between GrowthBook JSON values and OpenFeature values.
///
/// Unlike the SDK's value helpers, these never coerce between types or apply truthiness.
enum ValueConversion {
    static func bool(_ json: JSON) -> Bool? {
        json.type == .bool ? json.boolValue : nil
    }

    static func string(_ json: JSON) -> String? {
        json.type == .string ? json.stringValue : nil
    }

    /// Whole numbers within `Int64` range only; fractions and out-of-range values are rejected.
    static func int64(_ json: JSON) -> Int64? {
        guard json.type == .number, let number = json.number else { return nil }
        if isFloatingPoint(number) {
            return Int64(exactly: number.doubleValue)
        }
        // Integers above Int64.max arrive as unsigned values.
        guard number.compare(NSNumber(value: Int64.max)) != .orderedDescending else { return nil }
        return number.int64Value
    }

    static func double(_ json: JSON) -> Double? {
        guard json.type == .number, let number = json.number else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    static func value(_ json: JSON) -> Value? {
        switch json.type {
        case .bool:
            return .boolean(json.boolValue)
        case .string:
            return .string(json.stringValue)
        case .number:
            guard let number = json.number else { return nil }
            if !isFloatingPoint(number), let integer = int64(json) {
                return .integer(integer)
            }
            return double(json).map { .double($0) }
        case .array:
            var list: [Value] = []
            for element in json.arrayValue {
                guard let converted = value(element) else { return nil }
                list.append(converted)
            }
            return .list(list)
        case .dictionary:
            var structure: [String: Value] = [:]
            for (key, element) in json.dictionaryValue {
                guard let converted = value(element) else { return nil }
                structure[key] = converted
            }
            return .structure(structure)
        case .null:
            return .null
        default:
            return nil
        }
    }

    /// Converts an OpenFeature context value to a GrowthBook attribute value. Dates become ISO-8601 strings.
    static func attribute(from value: Value) -> Any {
        switch value {
        case .boolean(let bool):
            return bool
        case .string(let string):
            return string
        case .integer(let integer):
            return integer
        case .double(let double):
            return double
        case .date(let date):
            return iso8601.string(from: date)
        case .list(let list):
            return list.map(attribute(from:))
        case .structure(let structure):
            return structure.mapValues(attribute(from:))
        case .null:
            return NSNull()
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func isFloatingPoint(_ number: NSNumber) -> Bool {
        CFNumberIsFloatType(number)
    }
}
