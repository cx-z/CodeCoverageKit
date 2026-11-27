#if CODE_COVERAGE_KIT_ENABLED
import CryptoKit
import Foundation

/// Implements the metadata subset of Python ensure_ascii=False, sorted keys, compact JSON.
enum CoverageCanonicalJSON {
    /// Serializes only strings, integers, arrays and dictionaries; booleans/floats are outside Run metadata.
    static func encode(_ value: Any) throws -> Data {
        if let t_dictionary = value as? [String: Any] {
            let t_pairs = try t_dictionary.keys.sorted().map { try encode($0) + Data(":".utf8) + encode(t_dictionary[$0]!) }
            return Data("{".utf8) + t_pairs.joinedData(separator: Data(",".utf8)) + Data("}".utf8)
        }
        if let t_array = value as? [Any] {
            return Data("[".utf8) + (try t_array.map(encode)).joinedData(separator: Data(",".utf8)) + Data("]".utf8)
        }
        if let t_text = value as? String {
            var t_output = "\""
            for t_scalar in t_text.unicodeScalars {
                switch t_scalar.value {
                case 34: t_output += "\\\""
                case 92: t_output += "\\\\"
                case 8: t_output += "\\b"
                case 9: t_output += "\\t"
                case 10: t_output += "\\n"
                case 12: t_output += "\\f"
                case 13: t_output += "\\r"
                case 0...31: t_output += String(format: "\\u%04x", t_scalar.value)
                default: t_output.unicodeScalars.append(t_scalar)
                }
            }
            return Data((t_output + "\"").utf8)
        }
        if let t_number = value as? NSNumber, CFGetTypeID(t_number) != CFBooleanGetTypeID(),
           !Set(["f", "d"]).contains(String(cString: t_number.objCType)) {
            return Data(t_number.stringValue.utf8)
        }
        throw CocoaError(.propertyListWriteInvalid)
    }

    /// Binds canonical metadata and payloads to lowercase SHA-256 without logging bytes.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Array where Element == Data {
    /// Joins encoded JSON fragments without lossy string conversion.
    func joinedData(separator: Data) -> Data {
        var t_result = Data()
        for (t_index, t_value) in enumerated() {
            if t_index > 0 { t_result.append(separator) }
            t_result.append(t_value)
        }
        return t_result
    }
}
#endif
