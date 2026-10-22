import Foundation

public struct PlateCandidate: Equatable, Sendable {
    public let id: String
    public let plate: String
    public let observedAt: Date
    public let distance: Double
    public init(id: String, plate: String, observedAt: Date, distance: Double) {
        self.id = id; self.plate = plate; self.observedAt = observedAt; self.distance = distance
    }
}

public enum PlateRecognition {
    private static func folded(_ text: String) -> String {
        text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).uppercased()
    }
    public static func normalized(_ text: String) -> String {
        folded(text).filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    /// Candidates must already belong to the selected route and direction. OCR
    /// never guesses O/0, supplies a new bus, or automatically confirms boarding.
    public static func matches(text: [String], candidates: [PlateCandidate], at now: Date = Date()) -> [PlateCandidate] {
        let observations = text.prefix(50).map { folded(String($0.prefix(500))) }
        var seen = Set<String>()
        return candidates.filter { candidate in
            let age = now.timeIntervalSince(candidate.observedAt)
            guard (-15...90).contains(age), candidate.distance.isFinite, (0...300).contains(candidate.distance),
                  seen.insert(candidate.id).inserted else { return false }
            let plate = normalized(candidate.plate)
            guard (5...8).contains(plate.count), plate.contains(where: \.isLetter), plate.contains(where: \.isNumber) else { return false }
            let pattern = "(?<![A-Z0-9])" + plate.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[-\\s]*") + "(?![A-Z0-9])"
            return observations.contains { $0.range(of: pattern, options: .regularExpression) != nil }
        }.sorted { $0.distance == $1.distance ? $0.id < $1.id : $0.distance < $1.distance }
    }
}
