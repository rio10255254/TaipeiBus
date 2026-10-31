import Foundation

/// Something the voice assistant asked the app to do. Untrusted: it comes from a model, so each case
/// carries only words the app looks up itself, and anything that changes the trip is only ever asked.
public enum VoiceAction: Equatable, Sendable {
    case showStop(String)
    case showRoute(String)
    case followVehicle(route: String)
    case showBike(near: String)
    /// A place's Apple Maps card, with its opening hours, phone and website.
    case showPlace(String)
    /// `then` holds the later stops of 「先去 A 再去 B」, in the rider's words; `avoid` what the trip must
    /// not use (「坐公車去」 avoids the MRT).
    case planTrip(destination: String, origin: String, time: String, mode: String, preference: String, then: String, avoid: TripAvoidance)
    /// The first, second or third option on screen.
    case chooseOption(Int)
    /// One leg of a trip with several stops: the routes to its Nth stop (1 is the first).
    case showLeg(Int)
    /// The state had no answer: look these up and ask again.
    case lookup(stop: String, route: String)
    /// Read the Public Transportation Office's latest notices and ask again with them.
    case notices
    /// Look these names up on the map near the rider and ask again with what was found: a place the
    /// model was not sure of (a misheard name, a chain with several branches).
    case findPlace([String])
    /// The rider asked what is near (「找附近的爭鮮」): the app finds the nearest of it and says so itself,
    /// without asking the model again.
    case findNearby(String)
    /// Add a stop to the rider's favourites.
    case saveStop(String)
    /// Turn on the reminder to get off.
    case remindAlight
    case startNavigation, boarded, alighted, endTrip

    /// Changes the trip, so the rider says yes first.
    public var needsConfirmation: Bool {
        switch self {
        case .startNavigation, .boarded, .alighted, .endTrip: true
        default: false
        }
    }

    /// The server's shape: `{"type": "...", "stop": "", ...}`. nil for unknown types and for actions
    /// missing what they act on.
    public init?(json: [String: Any]) {
        func text(_ key: String, limit: Int = 60) -> String {
            String(((json[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        switch json["type"] as? String {
        case "show_stop": guard !text("stop").isEmpty else { return nil }; self = .showStop(text("stop"))
        case "show_route": guard !text("route").isEmpty else { return nil }; self = .showRoute(text("route"))
        case "follow_vehicle": guard !text("route").isEmpty else { return nil }; self = .followVehicle(route: text("route"))
        case "show_bike": self = .showBike(near: text("stop"))
        case "show_place":
            guard !text("destination").isEmpty else { return nil }
            self = .showPlace(text("destination"))
        case "plan_trip":
            guard !text("destination").isEmpty else { return nil }
            self = .planTrip(destination: text("destination"), origin: text("origin"), time: text("time", limit: 40),
                             mode: text("mode"), preference: text("preference"), then: text("then"),
                             avoid: TripAvoidance(json: json["avoid"]))
        case "choose_option":
            guard let option = json["option"] as? Int, (1...3).contains(option) else { return nil }
            self = .chooseOption(option)
        case "show_leg":
            guard let leg = json["option"] as? Int, (1...10).contains(leg) else { return nil }
            self = .showLeg(leg)
        case "lookup":
            guard !text("stop").isEmpty || !text("route").isEmpty else { return nil }
            self = .lookup(stop: text("stop"), route: text("route"))
        case "notices": self = .notices
        case "find_place":
            var names: [String] = []
            for part in text("query", limit: 100).split(whereSeparator: { "、,，;；".contains($0) }) {
                let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !names.contains(name) { names.append(String(name.prefix(40))) }
            }
            guard !names.isEmpty else { return nil }
            self = .findPlace(Array(names.prefix(3)))
        case "find_nearby": guard !text("query", limit: 40).isEmpty else { return nil }; self = .findNearby(text("query", limit: 40))
        case "save_stop": guard !text("stop").isEmpty else { return nil }; self = .saveStop(text("stop"))
        case "remind_alight": self = .remindAlight
        case "start_navigation": self = .startNavigation
        case "boarded": self = .boarded
        case "alighted": self = .alighted
        case "end_trip": self = .endTrip
        default: return nil
        }
    }
}

/// What a trip must not use, as the rider asked: buses, the MRT, YouBike, or named lines (307, 紅線).
public struct TripAvoidance: Equatable, Sendable {
    public var bus = false
    public var metro = false
    public var bike = false
    public var routes: [String] = []
    public var isEmpty: Bool { !bus && !metro && !bike && routes.isEmpty }

    public init(bus: Bool = false, metro: Bool = false, bike: Bool = false, routes: [String] = []) {
        self.bus = bus; self.metro = metro; self.bike = bike; self.routes = routes
    }

    /// The server's `{"bus": false, "metro": true, "bike": false, "routes": ["紅線"]}`; anything else is nothing.
    public init(json: Any?) {
        guard let value = json as? [String: Any] else { return }
        bus = value["bus"] as? Bool ?? false
        metro = value["metro"] as? Bool ?? false
        bike = value["bike"] as? Bool ?? false
        var names: [String] = []
        for case let route as String in (value["routes"] as? [Any]) ?? [] {
            let name = String(route.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        routes = Array(names.prefix(4))
    }
}

/// One answer of the voice conversation as the server returns it. `say` still has its `{r1}` slots;
/// it reaches the speaker only through `SpokenAnswer`.
public struct VoiceReply: Equatable, Sendable {
    public var say: String
    public var actions: [VoiceAction]
    /// Asked, not run: the rider's yes runs it.
    public var confirm: VoiceAction?
    public var choices: [String]
    public var followUp: Bool

    public init(say: String, actions: [VoiceAction] = [], confirm: VoiceAction? = nil, choices: [String] = [], followUp: Bool = false) {
        self.say = say; self.actions = actions; self.confirm = confirm; self.choices = choices; self.followUp = followUp
    }

    /// The server checks the same rules; the app checks again because the reply came from a model.
    public init?(json: [String: Any]) {
        let say = ((json["say"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // A web answer joins two replies' words; each sentence is still held to the spoken limit.
        guard !say.isEmpty, say.count <= 800 else { return nil }
        var confirm = (json["confirm"] as? [String: Any]).flatMap(VoiceAction.init(json:))
        if confirm?.needsConfirmation == false { confirm = nil }
        var actions: [VoiceAction] = []
        for item in (json["actions"] as? [[String: Any]]) ?? [] {
            guard let action = VoiceAction(json: item) else { continue }
            if action.needsConfirmation {
                if confirm == nil { confirm = action }
            } else if actions.count < 3 {
                actions.append(action)
            }
        }
        var seen = Set<String>()
        let choices = ((json["choices"] as? [Any]) ?? []).compactMap { $0 as? String }
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        self.init(say: say, actions: actions, confirm: confirm, choices: Array(choices.prefix(3)),
                  followUp: (json["followUp"] as? Bool) == true || confirm != nil)
    }
}

/// What the assistant is told about the app this turn, in words, and the values behind its slots.
/// The model sees each reference's meaning, never its value: the app fills `{r1}` when speaking.
public struct VoiceContext: Sendable {
    public struct Reference: Equatable, Sendable {
        public let id: String
        /// e.g. 307 往板橋 到 忠孝復興站 的到站預估
        public let meaning: String
        /// e.g. 約 4 分鐘到 — exactly as the app shows it.
        public let value: String
        public init(id: String, meaning: String, value: String) { self.id = id; self.meaning = meaning; self.value = value }
    }
    public var now: Date
    /// e.g. 導航中，第 2 段：搭 307 往板橋
    public var screen: String
    /// Short lines without numbers, e.g. 上車站：忠孝復興站.
    public var facts: [String]
    public var references: [Reference]
    /// The question the rider was last asked, waiting for a yes or no.
    public var pending: VoiceAction?
    /// Route and stop names the rider can see; numbers in them may be spoken.
    public var names: [String]

    public init(now: Date = Date(), screen: String, facts: [String] = [], references: [Reference] = [],
                pending: VoiceAction? = nil, names: [String] = []) {
        self.now = now; self.screen = screen; self.facts = facts; self.references = references
        self.pending = pending; self.names = names
    }

    /// References are numbered r1, r2… in the order given.
    public static func numbered(_ items: [(meaning: String, value: String)]) -> [Reference] {
        items.enumerated().map { Reference(id: "r\($0.offset + 1)", meaning: $0.element.meaning, value: $0.element.value) }
    }

    public var values: [String: String] {
        Dictionary(references.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// The state for the server, in plain lines.
    public func prompt(calendar: Calendar = AssistantJourneyRequest.calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_TW"); formatter.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        var lines = ["現在：\(formatter.string(from: now))（台北）", "畫面：\(screen)"]
        lines += facts
        if !references.isEmpty {
            lines.append("可用資料（念的時候寫成 {代號}）：")
            lines += references.map { "[\($0.id)] \($0.meaning)" }
        }
        if let pending { lines.append("待確認：\(pending.question)") }
        return lines.joined(separator: "\n")
    }
}

extension VoiceAction {
    /// What a pending action asks, for the state and the confirmation button.
    public var question: String {
        switch self {
        case .startNavigation: "開始導航"
        case .boarded: "已上車"
        case .alighted: "已下車"
        case .endTrip: "結束行程"
        case .showStop(let stop): "顯示 \(stop)"
        case .showRoute(let route), .followVehicle(let route): "顯示 \(route)"
        case .showBike: "顯示 YouBike"
        case .showPlace(let place): "顯示 \(place)"
        case .planTrip(let destination, _, _, _, _, _, _): "規劃到 \(destination)"
        case .chooseOption(let option): "選第 \(option) 個方案"
        case .showLeg(let leg): "看第 \(leg) 段"
        case .lookup, .notices, .findPlace: "查詢"
        case .findNearby(let query): "找附近的 \(query)"
        case .saveStop(let stop): "收藏 \(stop)"
        case .remindAlight: "下車提醒"
        }
    }
}

/// A time as it is said aloud in Taipei: 14:05 today, 明天 14:05 and 後天 14:05, otherwise 10/27 14:05.
/// Screen labels can be ranges across midnight (23:54–10/26 00:06); one time reads far better.
public enum VoiceClock {
    public static func label(_ date: Date, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let time = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let clock = String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
        switch days {
        case 0: return clock
        case 1: return "明天 " + clock
        case 2: return "後天 " + clock
        default: return "\(time.month ?? 0)/\(time.day ?? 0) " + clock
        }
    }
}

/// The answer as it streams in, cut into whole sentences so the first one can be spoken while the rest
/// is still being written. A sentence ends at 。！？ and takes any closing quote already there; a slot
/// never holds one, so it is never cut in half.
public struct SpokenSentences: Sendable {
    private var text = ""
    public init() {}

    /// The sentences this piece of the answer completes, in order.
    public mutating func push(_ piece: String) -> [String] {
        text += piece
        var sentences: [String] = []
        while let end = Self.end(in: text) {
            // A closing quote that arrived after its sentence went out is not spoken on its own.
            let sentence = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                .drop(while: Self.closers.contains).trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text[end...])
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }

    /// Whatever is left once the answer is complete: a last sentence without its full stop.
    public mutating func finish() -> String {
        defer { text = "" }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: Self.closers.contains))
    }

    private static let stops: Set<Character> = ["。", "！", "？", "!", "?", "\n"]
    private static let closers: Set<Character> = ["」", "』", "）", ")", "\""]

    /// Just past the first full stop and its closing quotes, once there is a sentence there. An English
    /// full stop ends a sentence only once a space follows, so 3.5 km stays whole.
    private static func end(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            guard stops.contains(character) || character == "." else { continue }
            var end = index
            while end < text.endIndex, closers.contains(text[end]) { end = text.index(after: end) }
            if character != "." { return end }
            if end < text.endIndex, text[end].isWhitespace { return end }
        }
        return nil
    }
}

/// One answer as it streams in. Each finished sentence is filled and checked like a whole answer and
/// handed out to be spoken as soon as it passes. One that cannot pass yet (its number may be one of the
/// choices or quoted sources that come with the end of the reply) holds back itself and everything after
/// it, so the answer is never spoken out of order. At the end each held sentence is checked once more;
/// one that still fails is left out and the rest are spoken.
public struct SpokenTurn: Sendable {
    private let values: [String: String]
    private let known: [String]
    private var sentences = SpokenSentences()
    private var held: [String] = []
    /// The sentences handed out, as filled in.
    public private(set) var spoken: [String] = []
    /// Why a held sentence was left out in the end.
    public private(set) var refused: SpokenAnswer.Failure?

    public init(context: VoiceContext, heard: String) {
        values = context.values
        known = context.names + [heard]
    }

    /// The sentences ready to speak after this piece of the answer.
    public mutating func receive(_ words: String) -> [String] { offer(sentences.push(words)) }

    /// All the words are in: the last sentence, even without a full stop.
    public mutating func finishWords() -> [String] {
        let rest = sentences.finish()
        return rest.isEmpty ? [] : offer([rest])
    }

    /// The reply is complete: what was held back, checked against its choices and the passages its
    /// sources quoted too.
    public mutating func finish(choices: [String], quoted: [String] = []) -> [String] {
        var lines = finishWords()
        let waiting = held
        held = []
        for sentence in waiting {
            switch SpokenAnswer.render(sentence, values: values, known: known + choices + quoted) {
            case .success(let line): spoken.append(line); lines.append(line)
            case .failure(let failure): refused = failure
            }
        }
        return lines
    }

    private mutating func offer(_ new: [String]) -> [String] {
        var lines: [String] = []
        for sentence in new {
            if held.isEmpty, case .success(let line) = SpokenAnswer.render(sentence, values: values, known: known) {
                spoken.append(line); lines.append(line)
            } else {
                held.append(sentence)
            }
        }
        return lines
    }
}

/// The sentence that is actually spoken: slots filled with the app's own values, and refused when it
/// still holds a number the app never gave, because a route, stop or time the model made up must not
/// reach the rider's ear.
public enum SpokenAnswer {
    public enum Failure: Error, Equatable { case empty, tooLong, unknownSlot(String), unsupportedNumber(String) }

    /// `known` is text the rider already saw or said: route and stop names, their own words.
    public static func render(_ say: String, values: [String: String], known: [String]) -> Result<String, Failure> {
        let text = say.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        let slot = try! NSRegularExpression(pattern: "\\{([A-Za-z0-9_]+)\\}")
        // Words between slots, and each slot's value: n + 1 texts around n values.
        var texts: [String] = [], filled: [String] = [], skeleton = "", cursor = text.startIndex
        for match in slot.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let key = Range(match.range(at: 1), in: text) else { continue }
            let id = String(text[key])
            guard let value = values[id] else { return .failure(.unknownSlot(id)) }
            texts.append(String(text[cursor..<range.lowerBound])); filled.append(value)
            skeleton += String(text[cursor..<range.lowerBound]) + " "
            cursor = range.upperBound
        }
        texts.append(String(text[cursor...])); skeleton += String(text[cursor...])
        if let number = unsupportedNumber(in: skeleton, known: known) { return .failure(.unsupportedNumber(number)) }
        for (index, value) in filled.enumerated() {
            texts[index] = withoutTrailingRepeat(texts[index], before: value)
            texts[index + 1] = withoutLeadingRepeat(texts[index + 1], after: value)
        }
        var sentence = texts[0]
        for (index, value) in filled.enumerated() { sentence += value + texts[index + 1] }
        guard sentence.count <= 240 else { return .failure(.tooLong) }
        return .success(sentence)
    }

    /// 「約 {r1}」 with r1 = 「約 5 分鐘」: the value already says it, so the words before it go.
    static func withoutTrailingRepeat(_ text: String, before value: String) -> String {
        let trimmed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let approximate = ["全程約", "大約", "約"]
        if approximate.contains(where: value.hasPrefix) || value.hasPrefix("全程") {
            for word in ["全程約", "全程", "大約", "約", "預計約"] where trimmed.hasSuffix(word) {
                return String(trimmed.dropLast(word.count))
            }
        }
        return text
    }

    /// 「{r1} 分鐘後到」 with r1 = 「5 分鐘」: the unit is said once. A status such as 尚未發車 takes no unit at all.
    static func withoutLeadingRepeat(_ text: String, after value: String) -> String {
        let trimmed = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        if value.hasSuffix("到"), trimmed.hasPrefix("到") { return String(trimmed.dropFirst()) }
        let timed = value.hasSuffix("分鐘") || value.hasSuffix("分")
        let status = !value.contains(where: \.isNumber)
        guard timed || status else { return text }
        for unit in (status ? ["分鐘後到", "分鐘到", "分鐘後", "分鐘", "分後"] : ["分鐘", "分"]) where trimmed.hasPrefix(unit) {
            return String(trimmed.dropFirst(unit.count))
        }
        return text
    }

    /// The first live figure in the model's own words that the rider has not seen or said: minutes,
    /// stops, buses, bikes and docks, which only the app can know. Fares, opening hours, years and route
    /// numbers are general knowledge the model may speak.
    static func unsupportedNumber(in text: String, known: [String]) -> String? {
        let haystack = known.map(normalized).joined(separator: "\n")
        let plain = normalized(text)
        let patterns = [
            "[0-9]+(?=\\s*(?:分鐘|分|站|班|輛|台|格|秒))",
            // 三分鐘, 兩站: Chinese numbers with a unit. 快一點 and the like ask for more of something,
            // 哪一班, 下一站, 這一班 name one rather than count, and 十分 alone means "very".
            "(?<![快慢早晚多少好差])(?:(?<![哪下上這那同每某])一|[零〇二兩三四五六七八九十百])[零〇一二兩三四五六七八九十百]*(分鐘|站|班|輛|格|秒)",
        ]
        for pattern in patterns {
            let expression = try! NSRegularExpression(pattern: pattern)
            for match in expression.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let range = Range(match.range, in: plain) else { continue }
                let number = String(plain[range])
                if !haystack.contains(number) { return number }
            }
        }
        return nil
    }

    /// The text handed to the speech voice: route numbers of three or more digits are read digit by digit,
    /// as riders say them (307 is 三零七, not 三百零七). The caption keeps the written form.
    public static func speakable(_ text: String, routes: [String]) -> String {
        let expression = try! NSRegularExpression(pattern: "[0-9]{3,}")
        let numbers = Set(routes.flatMap { route in
            expression.matches(in: route, range: NSRange(route.startIndex..., in: route)).compactMap { Range($0.range, in: route).map { String(route[$0]) } }
        })
        guard !numbers.isEmpty else { return text }
        var result = "", cursor = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let digits = String(text[range])
            result += String(text[cursor..<range.lowerBound])
            result += numbers.contains(digits) ? digits.map(String.init).joined(separator: " ") : digits
            cursor = range.upperBound
        }
        return result + String(text[cursor...])
    }

    /// Full-width digits read as ASCII, 臺 as 台, so 「３０７」 matches 307.
    static func normalized(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            (0xFF10...0xFF19).contains(scalar.value) ? Character(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!) : Character(scalar)
        }
        return String(scalars).replacingOccurrences(of: "臺", with: "台")
    }
}

/// A yes or no to the question just asked, read on the phone so it costs no turn.
public enum VoiceConfirmation: Equatable, Sendable {
    case yes, no, unclear

    private static let noWords = ["不要", "不用", "取消", "算了", "先不", "不是", "等一下", "不好"]
    private static let yesWords = ["好", "可以", "對", "是", "嗯", "開始", "出發", "確定", "沒問題", "走吧"]
    private static let englishNo: Set<String> = ["no", "nope", "cancel", "not", "don't", "dont", "stop", "wait", "later"]
    private static let englishYes: Set<String> = ["yes", "yeah", "yep", "ok", "okay", "sure", "go", "start", "please", "alright", "right", "correct"]

    /// A question is never a yes: 「是哪一站？」 and "where do I go" go to the server.
    private static let questionWords = ["嗎", "哪", "幾", "什麼", "怎", "誰", "呢", "為何"]
    private static let englishQuestions: Set<String> = ["what", "where", "when", "which", "who", "why", "how"]

    /// Only short answers count; anything longer is a new request for the server. English is read
    /// word by word, so "now" is not taken for "no".
    public static func read(_ text: String) -> VoiceConfirmation {
        if text.contains("?") || text.contains("？") { return .unclear }
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if lowered.unicodeScalars.contains(where: { $0.properties.isAlphabetic && $0.isASCII }) {
            let words = lowered.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
            guard !words.isEmpty, words.count <= 4, !words.contains(where: englishQuestions.contains) else { return .unclear }
            if words.contains(where: englishNo.contains) { return .no }
            if words.contains(where: englishYes.contains) { return .yes }
            return .unclear
        }
        let plain = lowered.replacingOccurrences(of: " ", with: "")
        guard !plain.isEmpty, plain.count <= 8, !questionWords.contains(where: plain.contains) else { return .unclear }
        if noWords.contains(where: plain.contains) { return .no }
        if plain.contains("不") { return .unclear }
        if yesWords.contains(where: plain.contains) { return .yes }
        return .unclear
    }
}

public struct VoiceHistory: Equatable, Sendable {
    public struct Turn: Equatable, Sendable {
        public let user: String
        /// What was spoken, with numbers filled.
        public let said: String
    }
    public private(set) var turns: [Turn] = []
    public init() {}
    public mutating func append(user: String, said: String) {
        turns = Array((turns + [Turn(user: String(user.prefix(300)), said: String(said.prefix(200)))]).suffix(VoiceHistory.limit))
    }
    public static let limit = 8
    public var json: [[String: String]] { turns.map { ["user": $0.user, "say": $0.said] } }
}

/// One of the choices on the panel, named or counted by the rider: 「淡水站」 or 「第二個」.
public enum VoiceChoice {
    public static func pick(_ text: String, among choices: [String]) -> Int? {
        let said = StationSearch.normalize(text)
        guard !said.isEmpty else { return nil }
        if let exact = choices.firstIndex(where: { StationSearch.normalize($0) == said }) { return exact }
        let named = choices.indices.filter { index in
            let choice = StationSearch.normalize(choices[index])
            return choice.count >= 2 && (said.contains(choice) || (said.count >= 2 && choice.contains(said)))
        }
        // 「淡水老街」 names 淡水老街 rather than 淡水: the longest name said wins.
        let length = { (index: Int) in StationSearch.normalize(choices[index]).count }
        if let longest = named.max(by: { length($0) < length($1) }), named.filter({ length($0) == length(longest) }).count == 1 {
            return longest
        }
        let ordinals = [["第一", "first"], ["第二", "second"], ["第三", "third"]]
        // Only a short answer is a count: 「第二個方案要走多久」 is a question.
        let short = said.allSatisfy(\.isASCII) ? said.count <= 16 : said.count <= 6
        for (index, words) in ordinals.enumerated() where index < choices.count && short {
            if words.contains(where: { said.contains($0) }) { return index }
        }
        return nil
    }
}

/// Whether words heard while the assistant speaks are the rider cutting in, or only the assistant's own
/// voice picked up again by the microphone. Chinese is compared by sound in pairs of syllables, so
/// 往 heard as 網 still matches, and 四 is 4; English word by word. The rider is cutting in once enough
/// of what was heard is nowhere in what was spoken.
/// How long a pause ends a turn. A rider who has to correct themselves (「我是說…」) was probably cut
/// off, so later turns wait a little longer for them; turns that go well bring it slowly back.
public enum VoicePatience {
    /// The pause the rider chose in Settings is `usual`; corrections add at most a second to it.
    public static let usual = 1.3
    public static func longest(usual: Double = usual) -> Double { usual + 1.0 }
    /// Said anywhere in the turn, or only at its start, where 「不是」 is a correction and not 「不是很遠」.
    private static let corrections = ["我是說", "我說的是", "我的意思是", "i mean", "i said"]
    private static let startsCorrecting = ["不是啦", "不是，", "不是,", "不對", "no, i", "no i"]

    public static func corrects(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return corrections.contains { text.contains($0) } || startsCorrecting.contains { text.hasPrefix($0) }
    }

    public static func next(_ pause: Double, after text: String, usual: Double = usual) -> Double {
        corrects(text) ? min(pause + 0.3, longest(usual: usual)) : max(pause - 0.05, usual)
    }
}

/// Sounds that are not words (「嗯」「呃…」): a breath, a cough or the answer trailing off, heard as a
/// turn of its own. Not sent on; a 「嗯」 that answers a question is read as a yes before this.
public enum VoiceNoise {
    private static let fillers = Set("嗯恩呃啊阿喔哦噢欸誒唉哎呀哈嘿呵mhu")
    public static func isFiller(_ text: String) -> Bool {
        let plain = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
        return plain.count <= 4 && plain.allSatisfy { fillers.contains($0) }
    }
}

/// The later stops of 「先去 A，再去 B，最後去 C」, one name each: as Claude lists them (「B、C」) or as
/// they were said (「B然後再去C」).
public enum TripStops {
    public static let limit = 5
    private static let joins = ["然後再去", "然後去", "然後到", "然後", "最後再去", "最後去", "最後到", "接著去", "接著到", "接著",
                                "之後再去", "之後去", "再去", "再到", "->", " and then ", " then "]

    public static func split(_ text: String) -> [String] {
        var value = text
        for join in joins { value = value.replacingOccurrences(of: join, with: "、", options: .caseInsensitive) }
        var names: [String] = []
        for part in value.split(whereSeparator: { "、，,;；→\n".contains($0) }) {
            var name = part.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            for lead in ["最後", "去", "到"] where name.hasPrefix(lead) && name.count > lead.count + 1 {
                name = String(name.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
            }
            guard !name.isEmpty, !names.contains(name) else { continue }
            names.append(name)
        }
        return Array(names.prefix(limit))
    }
}

public enum VoiceEcho {
    /// `strict` asks for more new words, for the loudspeaker, whose sound reaches the microphone.
    public static func interrupts(heard: String, spoken: String, strict: Bool = false) -> Bool {
        let said = Set(tokens(spoken))
        let new = tokens(heard).filter { !said.contains($0) }
        return new.count >= (strict ? 4 : 2)
    }

    /// What the rider said once they cut in: `heard` without the answer's own words that came first.
    /// `echo` is what had been heard of the answer; recognition often rewrites it a little once the
    /// rider's words follow (「往」 becomes 「網」, 「4」 becomes 「四」), so it is matched by sound, and
    /// only as far as the echo reaches.
    public static func removing(echo: String, from heard: String) -> String {
        let clean = { (text: Substring) in text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
        guard !echo.isEmpty else { return heard }
        if heard.hasPrefix(echo) { return clean(heard.dropFirst(echo.count)) }
        let echoed = units(echo), said = Set(echoed.map(\.sound))
        var matched = 0, misses = 0, cut: String.Index?
        for unit in units(heard).prefix(echoed.count + 2) {
            if said.contains(unit.sound) {
                matched += 1; misses = 0; cut = unit.end
            } else {
                misses += 1
                if misses == 2 { break }
            }
        }
        guard let cut, matched >= max(2, echoed.count / 2) else { return heard }
        return clean(heard[cut...])
    }

    /// Each Chinese character by its sound, each word of letters or digits as itself, with where it ends.
    private static func units(_ text: String) -> [(sound: String, end: String.Index)] {
        var units: [(sound: String, end: String.Index)] = [], word = "", index = text.startIndex
        func endWord() { if !word.isEmpty { units.append((word, index)); word = "" } }
        while index < text.endIndex {
            let character = digits[text[index]] ?? Character(text[index].lowercased())
            if let syllable = NameCorrection.syllable(character) {
                endWord()
                units.append((NameCorrection.loose(syllable), text.index(after: index)))
            } else if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                endWord()
            }
            index = text.index(after: index)
        }
        endWord()
        return units
    }

    private static let digits: [Character: Character] = ["零": "0", "〇": "0", "一": "1", "二": "2", "兩": "2", "三": "3",
                                                         "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"]

    /// Pairs of syllables in each stretch of Chinese, and lower-cased words of letters or digits.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = [], sounds: [String] = [], word = ""
        func endSounds() {
            if sounds.count == 1 { tokens.append(sounds[0]) }
            for index in sounds.indices.dropLast() { tokens.append(sounds[index] + "|" + sounds[index + 1]) }
            sounds = []
        }
        func endWord() { if !word.isEmpty { tokens.append(word); word = "" } }
        for character in text.lowercased() {
            let character = digits[character] ?? character
            if let syllable = NameCorrection.syllable(character) {
                endWord(); sounds.append(NameCorrection.loose(syllable))
            } else if character.isLetter || character.isNumber {
                endSounds(); word.append(character)
            } else {
                // Punctuation and spaces do not split syllables: recognition hears none of them.
                endWord()
            }
        }
        endSounds(); endWord()
        return tokens
    }
}
