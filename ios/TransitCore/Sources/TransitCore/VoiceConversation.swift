import Foundation

/// Something the voice assistant asked the app to do. Untrusted: it comes from a model, so each case
/// carries only words the app looks up itself, and anything that changes the trip is only ever asked.
public enum VoiceAction: Equatable, Sendable {
    case showStop(String)
    case showRoute(String)
    case followVehicle(route: String)
    case showBike(near: String)
    case planTrip(destination: String, origin: String, time: String, mode: String, preference: String)
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
        case "plan_trip":
            guard !text("destination").isEmpty else { return nil }
            self = .planTrip(destination: text("destination"), origin: text("origin"), time: text("time", limit: 40),
                             mode: text("mode"), preference: text("preference"))
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
        guard !say.isEmpty, say.count <= 160 else { return nil }
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
        case .planTrip(let destination, _, _, _, _): "規劃到 \(destination)"
        case .chooseOption(let option): "選第 \(option) 個方案"
        case .lookup: "查詢"
        }
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
        let whole = NSRange(text.startIndex..., in: text)
        var filled = "", skeleton = "", cursor = text.startIndex
        for match in slot.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text), let key = Range(match.range(at: 1), in: text) else { continue }
            let id = String(text[key])
            guard let value = values[id] else { return .failure(.unknownSlot(id)) }
            filled += String(text[cursor..<range.lowerBound]) + value
            skeleton += String(text[cursor..<range.lowerBound]) + " "
            cursor = range.upperBound
        }
        filled += String(text[cursor...]); skeleton += String(text[cursor...])
        if let number = unsupportedNumber(in: skeleton, known: known) { return .failure(.unsupportedNumber(number)) }
        guard filled.count <= 160 else { return .failure(.tooLong) }
        return .success(filled)
    }

    /// The first number in the model's own words that the rider has not seen or said.
    static func unsupportedNumber(in text: String, known: [String]) -> String? {
        let haystack = known.map(normalized).joined(separator: "\n")
        let plain = normalized(text)
        let patterns = [
            "[0-9]+",
            // 三分鐘, 兩站, 十點: Chinese numbers with a unit. 快一點, 早一點 and the like ask for more of something.
            "(?<![快慢早晚多少好差])[零〇一二兩三四五六七八九十百]+(分鐘|分|站|點|號|班|次|公里|公尺|秒|輛|格|元)",
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

    private static let noWords = ["不要", "不用", "取消", "算了", "先不", "不是", "等一下", "不好", "no", "nope", "cancel"]
    private static let yesWords = ["好", "可以", "對", "是", "嗯", "開始", "出發", "確定", "沒問題", "走吧", "ok", "okay", "yes", "sure"]

    /// Only short answers count; anything longer is a new request for the server.
    public static func read(_ text: String) -> VoiceConfirmation {
        let plain = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: " ", with: "")
        guard !plain.isEmpty, plain.count <= 8 else { return .unclear }
        if noWords.contains(where: plain.contains) { return .no }
        if plain.contains("不") { return .unclear }
        if yesWords.contains(where: plain.contains) { return .yes }
        return .unclear
    }
}

/// The last two turns, sent back each time so 「那回程呢」 has something to refer to.
public struct VoiceHistory: Equatable, Sendable {
    public struct Turn: Equatable, Sendable {
        public let user: String
        /// What was spoken, with numbers filled.
        public let said: String
    }
    public private(set) var turns: [Turn] = []
    public init() {}
    public mutating func append(user: String, said: String) {
        turns = Array((turns + [Turn(user: String(user.prefix(300)), said: String(said.prefix(200)))]).suffix(2))
    }
    public var json: [[String: String]] { turns.map { ["user": $0.user, "say": $0.said] } }
}
