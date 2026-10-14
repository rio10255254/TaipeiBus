import Foundation

/// Reads single stops out of the city's public arrival file without decoding all of it, for the
/// widget extension, which has a small memory limit.
public enum EstimateScan {
    public static func updateTime(_ data: Data) -> Date? {
        guard let start = data.range(of: Data("\"UpdateTime\":\"".utf8)),
              let end = data[start.upperBound..<min(data.endIndex, start.upperBound + 40)].firstIndex(of: UInt8(ascii: "\"")),
              let text = String(data: data[start.upperBound..<end], encoding: .utf8) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.date(from: text)
    }

    /// Finds each `"StopID":<stop>` and decodes just its enclosing record.
    public static func estimate(in data: Data, route: String, stop: String) -> Int? {
        let open = UInt8(ascii: "{"), close = UInt8(ascii: "}")
        for needle in ["\"StopID\":" + stop, "\"StopID\":\"" + stop + "\""] {
            var cursor = data.startIndex
            let pattern = Data(needle.utf8)
            while let match = data.range(of: pattern, in: cursor..<data.endIndex) {
                cursor = match.upperBound
                if match.upperBound < data.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(data[match.upperBound]) { continue }
                let lower = max(data.startIndex, match.lowerBound - 160), upper = min(data.endIndex, match.upperBound + 160)
                guard let begin = data[lower..<match.lowerBound].lastIndex(of: open),
                      let finish = data[match.upperBound..<upper].firstIndex(of: close),
                      let row = try? JSONSerialization.jsonObject(with: data[begin...finish]) as? [String: Any],
                      "\(row["RouteID"] ?? "")" == route else { continue }
                let value = row["EstimateTime"]
                if let number = value as? NSNumber { return number.intValue }
                if let text = value as? String, let number = Int(text) { return number }
            }
        }
        return nil
    }
}
