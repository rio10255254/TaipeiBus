import Foundation

/// A trip described in one sentence ("從公司到台大醫院，少走路"), as read by the on-device language model.
/// The model only proposes this structure; places are still found by the normal place search and
/// chosen by the rider, and routes and times always come from the planner.
public struct TripIntent: Equatable, Sendable {
    public enum Preference: String, CaseIterable, Sendable {
        case balanced, faster, lessWalking, fewerTransfers
    }
    /// Search text for the destination, taken from the rider's own words.
    public var destination: String
    /// Search text for the start; nil means the current location.
    public var origin: String?
    public var preference: Preference
    /// A departure or arrival time the rider mentioned. The planner only plans to leave now,
    /// so the App says so instead of silently dropping it.
    public var timeText: String?
    /// A saved trip whose title the sentence named ("回家").
    public var savedJourneyTitle: String?

    public init(destination: String, origin: String? = nil, preference: Preference = .balanced,
                timeText: String? = nil, savedJourneyTitle: String? = nil) {
        self.destination = destination; self.origin = origin; self.preference = preference
        self.timeText = timeText; self.savedJourneyTitle = savedJourneyTitle
    }

    /// Accepts the model's fields only when they stay inside the rider's sentence: a place the
    /// rider never wrote is a guess, and a guessed destination is worse than none. Empty strings
    /// mean "not mentioned". Returns nil when nothing usable remains.
    public static func validated(sentence: String, destination: String, origin: String, preference: String,
                                 time: String, savedJourney: String, savedTitles: [String]) -> TripIntent? {
        let said = StationSearch.normalize(sentence)
        guard !said.isEmpty else { return nil }
        func phrase(_ value: String) -> String? {
            let text = StationSearch.cleanQuery(value).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let key = StationSearch.normalize(text)
            guard !key.isEmpty, text.count <= 60, said.contains(key) else { return nil }
            return text
        }
        let title = savedTitles.first { !savedJourney.isEmpty && StationSearch.normalize($0) == StationSearch.normalize(savedJourney) }
            .flatMap { said.contains(StationSearch.normalize($0)) ? $0 : nil }
        var start = phrase(origin)
        if let value = start, currentLocationWords.contains(StationSearch.normalize(value)) { start = nil }
        let target = phrase(destination)
        // Without a destination the sentence can only open a saved trip.
        guard target != nil || title != nil else { return nil }
        if let target, let value = start, StationSearch.normalize(value) == StationSearch.normalize(target) { start = nil }
        return TripIntent(destination: target ?? title ?? "", origin: start,
                          preference: Preference(rawValue: preference) ?? .balanced,
                          timeText: phrase(time), savedJourneyTitle: title)
    }

    private static let currentLocationWords: Set<String> = Set(["這裡", "這邊", "目前位置", "現在位置", "我的位置", "here", "currentlocation", "mylocation"]
        .map(StationSearch.normalize))

    /// Whether to offer reading the whole sentence. Plain place names keep the ordinary search,
    /// which already handles phrasing such as "我要去…", so the model is never run needlessly.
    public static func isSentence(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...160).contains(value.count) else { return false }
        let lower = value.lowercased()
        // Words that only a trip description needs: a start, a preference or a time.
        let cues = ["從", "出發", "不想", "不要", "少走", "少轉", "不轉", "最快", "快一點", "趕時間", "避開", "直達",
                    "點前", "點到", "點出發", "明天", "今天", "早上", "晚上", "下午", "回家", "去公司", "上班", "下班",
                    "from ", "fastest", "less walking", "fewer transfers", "no transfer", "avoid", "before ", "tomorrow", "home"]
        return cues.contains { lower.contains($0) }
    }
}
