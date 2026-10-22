import Foundation

/// Untrusted language-model output. It contains search parameters, never a route,
/// coordinate, departure prediction, vehicle identity or generated travel time.
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

    public init(destination: String, origin: String = "", preference: Preference = .balanced,
                preferenceEvidence: String = "", timeEvidence: String = "", arrivalDay: String = "",
                arrivalHour: Int = -1, arrivalMinute: Int = -1, needsClarification: Bool = false) {
        self.destination = destination; self.origin = origin; self.preference = preference
        self.preferenceEvidence = preferenceEvidence; self.timeEvidence = timeEvidence
        self.arrivalDay = arrivalDay; self.arrivalHour = arrivalHour; self.arrivalMinute = arrivalMinute
        self.needsClarification = needsClarification
    }

    public enum ValidationError: Error, Equatable { case input, destination, origin, preference, time, clarification }

    /// All extracted phrases must occur in the user's input. The user still reviews
    /// these fields and selects a real search result before any planner runs.
    public func validated(source: String, now: Date = Date()) throws -> AssistantJourneyRequest {
        let input = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 600 else { throw ValidationError.input }
        guard !needsClarification else { throw ValidationError.clarification }
        func literal(_ phrase: String) -> Bool {
            !phrase.isEmpty && phrase.count <= 120 && input.range(of: phrase, options: [.caseInsensitive, .widthInsensitive]) != nil
        }
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard literal(destination) else { throw ValidationError.destination }
        guard origin.isEmpty || literal(origin) else { throw ValidationError.origin }
        guard preference == .balanced || literal(preferenceEvidence) else { throw ValidationError.preference }
        var arriveBy: Date?
        if !timeEvidence.isEmpty || !arrivalDay.isEmpty || arrivalHour != -1 || arrivalMinute != -1 {
            guard literal(timeEvidence), (0...23).contains(arrivalHour), (0...59).contains(arrivalMinute),
                  arrivalDay.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw ValidationError.time }
            let parts = arrivalDay.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { throw ValidationError.time }
            let calendar = AssistantJourneyRequest.calendar
            let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: arrivalHour, minute: arrivalMinute)
            guard let date = calendar.date(from: components),
                  calendar.component(.year, from: date) == parts[0], calendar.component(.month, from: date) == parts[1],
                  calendar.component(.day, from: date) == parts[2], calendar.component(.hour, from: date) == arrivalHour,
                  calendar.component(.minute, from: date) == arrivalMinute,
                  date > now, date.timeIntervalSince(now) <= 90 * 86_400 else { throw ValidationError.time }
            arriveBy = date
        }
        return AssistantJourneyRequest(destination: destination, origin: origin, preference: preference, arriveBy: arriveBy)
    }
}

public struct AssistantJourneyRequest: Equatable, Sendable {
    public var destination: String
    public var origin: String
    public var preference: AssistantIntentDraft.Preference
    public var arriveBy: Date?
    public init(destination: String, origin: String = "", preference: AssistantIntentDraft.Preference = .balanced, arriveBy: Date? = nil) {
        self.destination = destination; self.origin = origin; self.preference = preference; self.arriveBy = arriveBy
    }
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }
}
