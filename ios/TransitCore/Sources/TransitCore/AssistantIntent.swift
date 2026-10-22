import Foundation

public enum AssistantFieldStatus: String, Codable, Sendable {
    case certain, needsConfirmation
}

/// Confidence describes interpretation only. Even a certain place must be selected
/// from real search/library data and confirmed by the user before planning.
public struct AssistantFieldReview: Equatable, Codable, Sendable {
    public var destination: AssistantFieldStatus
    public var origin: AssistantFieldStatus
    public var preference: AssistantFieldStatus
    public var time: AssistantFieldStatus
    public init(destination: AssistantFieldStatus = .needsConfirmation, origin: AssistantFieldStatus = .needsConfirmation,
                preference: AssistantFieldStatus = .needsConfirmation, time: AssistantFieldStatus = .needsConfirmation) {
        self.destination = destination; self.origin = origin; self.preference = preference; self.time = time
    }
    public var needsConfirmation: Bool {
        [destination, origin, preference, time].contains(.needsConfirmation)
    }
}

/// Untrusted model output contains search parameters, never routes, coordinates,
/// departure predictions, vehicle identities or generated travel times.
public struct AssistantIntentDraft: Equatable, Sendable {
    public enum Preference: String, CaseIterable, Codable, Sendable {
        case balanced, faster, lessWalking, fewerTransfers
    }
    public var destination: String
    public var origin: String
    public var preference: Preference
    public var preferenceEvidence: String
    public var timeEvidence: String
    public var arrivalDay: String
    public var arrivalHour: Int
    public var arrivalMinute: Int
    public var needsClarification: Bool
    public var review: AssistantFieldReview

    public init(destination: String, origin: String = "", preference: Preference = .balanced,
                preferenceEvidence: String = "", timeEvidence: String = "", arrivalDay: String = "",
                arrivalHour: Int = -1, arrivalMinute: Int = -1, needsClarification: Bool = false,
                review: AssistantFieldReview = .init()) {
        self.destination = destination; self.origin = origin; self.preference = preference
        self.preferenceEvidence = preferenceEvidence; self.timeEvidence = timeEvidence
        self.arrivalDay = arrivalDay; self.arrivalHour = arrivalHour; self.arrivalMinute = arrivalMinute
        self.needsClarification = needsClarification; self.review = review
    }

    public enum ValidationError: Error, Equatable { case input }

    /// Converts every usable field to an editable review. Semantic uncertainty is
    /// never a rejection; malformed/out-of-range dates remain visible for correction.
    public func validated(source: String, now: Date = Date()) throws -> AssistantJourneyRequest {
        let input = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 600 else { throw ValidationError.input }
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        var review = review
        if destination.isEmpty { review.destination = .needsConfirmation }
        if needsClarification && !review.needsConfirmation { review = .init() }
        var arriveBy: Date?
        let hasDate = !arrivalDay.isEmpty || arrivalHour != -1 || arrivalMinute != -1
        if hasDate {
            let rawParts = arrivalDay.split(separator: "-", omittingEmptySubsequences: false)
            let parts = rawParts.compactMap { Int($0) }
            if rawParts.count == 3, parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]),
               (0...23).contains(arrivalHour), (0...59).contains(arrivalMinute) {
                let calendar = AssistantJourneyRequest.calendar
                let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: arrivalHour, minute: arrivalMinute)
                if let date = calendar.date(from: components),
                   calendar.component(.year, from: date) == parts[0], calendar.component(.month, from: date) == parts[1],
                   calendar.component(.day, from: date) == parts[2], calendar.component(.hour, from: date) == arrivalHour,
                   calendar.component(.minute, from: date) == arrivalMinute,
                   AssistantJourneyRequest.canPlan(arriveBy: date, now: now) { arriveBy = date }
            }
        }
        if (hasDate || !timeEvidence.isEmpty) && arriveBy == nil { review.time = .needsConfirmation }
        let timeDescription = timeEvidence.isEmpty && hasDate ? "\(arrivalDay) \(arrivalHour):\(arrivalMinute)" : timeEvidence
        return AssistantJourneyRequest(destination: destination, origin: origin, preference: preference,
            arriveBy: arriveBy, review: review, timeDescription: timeDescription)
    }
}

public struct AssistantJourneyRequest: Equatable, Codable, Sendable {
    public var destination: String
    public var origin: String
    public var preference: AssistantIntentDraft.Preference
    public var arriveBy: Date?
    public var review: AssistantFieldReview
    public var timeDescription: String
    public init(destination: String, origin: String = "", preference: AssistantIntentDraft.Preference = .balanced,
                arriveBy: Date? = nil, review: AssistantFieldReview = .init(), timeDescription: String = "") {
        self.destination = destination; self.origin = origin; self.preference = preference; self.arriveBy = arriveBy
        self.review = review; self.timeDescription = timeDescription
    }
    public static func canPlan(arriveBy: Date, now: Date = Date()) -> Bool {
        arriveBy > now && arriveBy.timeIntervalSince(now) <= 90 * 86_400
    }
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }
}

public struct AssistantClarification: Equatable, Codable, Sendable {
    public let question: String
    public let options: [String]
    public init?(question: String, options: [String]) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let choices = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !question.isEmpty, choices.count >= 2 else { return nil }
        self.question = question; self.options = Array(choices.prefix(3))
    }
}
