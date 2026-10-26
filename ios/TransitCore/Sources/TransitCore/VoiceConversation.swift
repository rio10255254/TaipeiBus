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
    /// `then` holds the later stops of 「先去 A 再去 B」, in the rider's words.
    case planTrip(destination: String, origin: String, time: String, mode: String, preference: String, then: String)
    /// The first, second or third option on screen.
    case chooseOption(Int)
    /// The state had no answer: look these up and ask again.
    case lookup(stop: String, route: String)
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
                             mode: text("mode"), preference: text("preference"), then: text("then"))
        case "choose_option":
            guard let option = json["option"] as? Int, (1...3).contains(option) else { return nil }
            self = .chooseOption(option)
        case "lookup":
            guard !text("stop").isEmpty || !text("route").isEmpty else { return nil }
            self = .lookup(stop: text("stop"), route: text("route"))
        case "start_navigation": self = .startNavigation
        case "boarded": self = .boarded
        case "alighted": self = .alighted
        case "end_trip": self = .endTrip
        default: return nil
        }
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
        case .planTrip(let destination, _, _, _, _, _): "規劃到 \(destination)"
        case .chooseOption(let option): "選第 \(option) 個方案"
        case .lookup: "查詢"
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
