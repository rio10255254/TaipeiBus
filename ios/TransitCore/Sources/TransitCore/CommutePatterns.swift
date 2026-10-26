import Foundation

/// An opt-in local history: only an existing saved-journey ID and its start time.
/// No location trace, search text or model prompt is retained.
public struct CommutePatterns: Codable, Equatable, Sendable {
    public struct Event: Codable, Equatable, Sendable {
        public let journeyID: UUID
        public let startedAt: Date
        public init(journeyID: UUID, startedAt: Date) { self.journeyID = journeyID; self.startedAt = startedAt }
    }
    public private(set) var events: [Event]
    public init(events: [Event] = []) { self.events = Array(events.suffix(240)) }
    public mutating func prune(at now: Date, keeping ids: Set<UUID>? = nil) {
        events = Array(events.filter {
            now.timeIntervalSince($0.startedAt) >= 0 && now.timeIntervalSince($0.startedAt) <= 42 * 86_400 &&
            (ids?.contains($0.journeyID) ?? true)
        }.sorted { $0.startedAt < $1.startedAt }.suffix(240))
    }
    public mutating func record(journeyID: UUID, at now: Date) {
        prune(at: now)
        guard !events.contains(where: { $0.journeyID == journeyID && now.timeIntervalSince($0.startedAt) < 3600 }) else { return }
        events.append(Event(journeyID: journeyID, startedAt: now))
        events = Array(events.suffix(240))
    }
    /// When each saved journey usually starts on weekdays, in minutes after midnight (Taipei): the middle
    /// start of those used on at least three weekdays in the last six weeks, most used first.
    public func usualWeekdayStarts(available ids: Set<UUID>, at now: Date) -> [(journeyID: UUID, minute: Int)] {
        let calendar = AssistantJourneyRequest.calendar
        let weekdays = events.filter {
            ids.contains($0.journeyID) && (0...(42 * 86_400)).contains(now.timeIntervalSince($0.startedAt)) &&
                (2...6).contains(calendar.component(.weekday, from: $0.startedAt))
        }
        return Dictionary(grouping: weekdays, by: \.journeyID).compactMap { id, history -> (UUID, Int, Int)? in
            guard Set(history.map { calendar.startOfDay(for: $0.startedAt) }).count >= 3 else { return nil }
            let minutes = history.map { calendar.component(.hour, from: $0.startedAt) * 60 + calendar.component(.minute, from: $0.startedAt) }.sorted()
            return (id, minutes[minutes.count / 2], history.count)
        }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0.uuidString < $1.0.uuidString }.map { ($0.0, $0.1) }
    }

    public func suggestions(available ids: Set<UUID>, at now: Date) -> [UUID] {
        let calendar = AssistantJourneyRequest.calendar
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let weekday = calendar.component(.weekday, from: now)
        func sameDayKind(_ date: Date) -> Bool {
            let other = calendar.component(.weekday, from: date)
            return (2...6).contains(weekday) ? (2...6).contains(other) : weekday == other
        }
        let eligible = events.filter {
            guard ids.contains($0.journeyID), (0...(42 * 86_400)).contains(now.timeIntervalSince($0.startedAt)), sameDayKind($0.startedAt) else { return false }
            let other = calendar.component(.hour, from: $0.startedAt) * 60 + calendar.component(.minute, from: $0.startedAt)
            let difference = abs(minute - other)
            return min(difference, 1440 - difference) <= 45
        }
        return Dictionary(grouping: eligible, by: \.journeyID).compactMap { id, history -> (UUID, Int, Date)? in
            let days = Set(history.map { calendar.startOfDay(for: $0.startedAt) })
            guard days.count >= 3 else { return nil }
            return (id, days.count, history.map(\.startedAt).max()!)
        }.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.2 != b.2 { return a.2 > b.2 }
            return a.0.uuidString < b.0.uuidString
        }.prefix(2).map(\.0)
    }
}
