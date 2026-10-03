import Foundation

public struct StationResultGroup: Identifiable, Sendable {
    public let name: String
    public let stations: [Station]
    public var id: String { name }
}

/// Shared matching for official platforms and native place results.
public enum StationSearch {
    private static let familiarNames = [
        ["台北車站", "台北站", "北車", "Taipei Main Station"],
        ["台北101", "101", "Taipei 101", "台北101購物中心"],
        ["台大", "台灣大學", "國立台灣大學", "National Taiwan University", "NTU"],
        ["台大醫院", "國立台灣大學醫學院附設醫院", "National Taiwan University Hospital"],
        ["三總", "三軍總醫院", "Tri-Service General Hospital"],
        ["小巨蛋", "台北小巨蛋", "Taipei Arena"],
        ["榮總", "台北榮總", "台北榮民總醫院"],
        ["松山機場", "台北松山機場", "Taipei Songshan Airport"],
        ["台北市政府", "北市府", "臺北市政府"],
        ["台北轉運站", "臺北轉運站", "Taipei Bus Station"]
    ]
    private static let queryNames: [String: [String]] = [
        "台北101": ["Taipei 101", "台北101"], "101": ["Taipei 101", "台北101"],
        "台大": ["國立台灣大學", "National Taiwan University"], "ntu": ["National Taiwan University", "國立台灣大學"],
        "北車": ["台北車站", "Taipei Main Station"], "三總": ["三軍總醫院", "Tri-Service General Hospital"],
        "小巨蛋": ["台北小巨蛋", "Taipei Arena"], "榮總": ["台北榮民總醫院"],
        "北市府": ["臺北市政府"], "台北轉運站": ["臺北轉運站"]
    ]
    private static let familiarAliases = familiarNames.map { Set($0.map(normalize)) }
    public static func cleanQuery(_ text: String) -> String {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        for prefix in ["我要去", "我想去", "想去", "前往", "去", "到"] where trimmed.hasPrefix(prefix) && trimmed.count > prefix.count + 2 {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
    public static func normalize(_ text: String) -> String {
        let traditional = text.applyingTransform(StringTransform(rawValue: "Simplified-Traditional"), reverse: false) ?? text
        var value = traditional.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_TW"))
            .replacingOccurrences(of: "臺", with: "台")
        for (index, digit) in Array("一二三四五六七八九").enumerated() {
            value = value.replacingOccurrences(of: String(digit) + "段", with: String(index + 1) + "段")
        }
        return value.filter { $0.isLetter || $0.isNumber }
    }
    fileprivate static func baseName(_ text: String) -> String {
        text.components(separatedBy: CharacterSet(charactersIn: "(（")).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
    }
    fileprivate static func aliases(_ text: String, normalized: String? = nil) -> Set<String> {
        let full = normalized ?? normalize(text)
        let baseText = baseName(text)
        let base = baseText == text ? full : normalize(baseText)
        var values: Set<String> = [full, base]
        var metro: String?
        if base.hasPrefix("捷運站"), base.count > 3 { metro = String(base.dropFirst(3)) }
        else if base.hasPrefix("捷運"), base.count > 2 { metro = String(base.dropFirst(2)) }
        else if base.hasSuffix("捷運站"), base.count > 3 { metro = String(base.dropLast(3)) }
        else if base.hasSuffix("捷運"), base.count > 2 { metro = String(base.dropLast(2)) }
        if let metro {
            let core = metro.hasSuffix("站") ? String(metro.dropLast()) : metro
            values.formUnion([core, core + "站", "捷運" + core + "站", core + "捷運站", core + "捷運"])
        }
        if base.hasSuffix("站"), !base.hasSuffix("車站") { values.insert(String(base.dropLast())) }
        var english = base.hasPrefix("mrt") ? String(base.dropFirst(3)) : base
        if english.hasSuffix("station") { english = String(english.dropLast(7)) }
        else if english.hasSuffix("sta") { english = String(english.dropLast(3)) }
        if english != base, !english.isEmpty { values.insert(english) }
        for names in familiarAliases where !values.isDisjoint(with: names) { values.formUnion(names) }
        values.remove("")
        return values
    }
    public static func rank(name: String, query: String, vocabulary: SearchVocabulary = SearchVocabulary()) -> Int? {
        let input = SearchQuery(query, vocabulary: vocabulary)
        let indexed = IndexedName(name)
        return indexed.simpleRank(input) ?? indexed.fuzzyRank(input)
    }
    public static func placeRank(name: String, address: String, query: String, vocabulary: SearchVocabulary = SearchVocabulary()) -> Int? {
        PlaceMatcher(query: query, vocabulary: vocabulary).rank(name: name, address: address)
    }
    fileprivate static func placeRank(name: String, address: String, input: SearchQuery) -> Int? {
        let indexed = IndexedName(name)
        if let rank = indexed.simpleRank(input) ?? indexed.fuzzyRank(input) { return rank }
        guard input.addressLike || !input.hasDigits else { return nil }
        let address = normalize(address)
        if input.aliases.contains(where: { $0.count >= 2 && address.contains($0) }), input.addressLike { return 4 }
        if address.contains(input.text), !input.text.isEmpty { return 4 }
        if input.tokens.count > 1, input.tokens.allSatisfy({ indexed.full.contains($0) || address.contains($0) }) { return 4 }
        return indexed.fuzzyRank(input)
    }
    public static func search(_ query: String, metadata: TransitMetadata, near position: Coordinate,
                              favorites: Set<String> = [], recent: [String] = [], limit: Int = 40,
                              vocabulary: SearchVocabulary = SearchVocabulary()) -> [Station] {
        StationSearchIndex(stations: Array(metadata.stations.values)).search(query, near: position, favorites: favorites, recent: recent, limit: limit, vocabulary: vocabulary)
    }
    public static func groups(_ stations: [Station]) -> [StationResultGroup] {
        var names: [String] = [], groups: [String: [Station]] = [:]
        for station in stations {
            let name = baseName(station.name)
            if groups[name] == nil { names.append(name) }
            groups[name, default: []].append(station)
        }
        return names.map { StationResultGroup(name: $0, stations: groups[$0] ?? []) }
    }
    public static func placeQueries(_ query: String, vocabulary: SearchVocabulary = SearchVocabulary()) -> [String] {
        let text = cleanQuery(query)
        guard !text.isEmpty else { return [] }
        if let queries = vocabulary.placeQueries(text) { return queries + (queries.contains(text) ? [] : [text]) }
        let normalized = normalize(text)
        if let aliases = queryNames[normalized] { return Array((aliases + [text]).prefix(3)) }
        let traditional = text.applyingTransform(StringTransform(rawValue: "Simplified-Traditional"), reverse: false) ?? text
        let standard = traditional.replacingOccurrences(of: "臺", with: "台")
        if normalized.hasSuffix("站"), !normalized.hasPrefix("捷運"), !normalized.hasSuffix("車站"), !normalized.hasSuffix("捷運站") {
            for city in ["台北市", "新北市", "台北", "新北"] where normalized.hasPrefix(city) && normalized.count > city.count + 2 {
                return [city + " 捷運" + String(normalized.dropFirst(city.count)), standard]
            }
            // Facility stops keep their actual name instead of becoming an invented metro station.
            if ["醫院", "三總", "榮總", "轉運", "公車", "總站"].contains(where: normalized.contains) { return [standard] }
            return ["捷運" + standard, standard]
        }
        return standard == text ? [text] : [standard, text]
    }
    public static func isAddressQuery(_ query: String) -> Bool { SearchQuery(query).addressLike }
    public static func isTransitQuery(_ query: String) -> Bool {
        let text = normalize(cleanQuery(query))
        if text.contains("捷運") || text.hasPrefix("mrt") { return true }
        if text.hasSuffix("station") {
            return !["gasstation", "workstation", "weatherstation", "policestation", "chargingstation"].contains(where: text.hasSuffix)
        }
        return text.hasSuffix("站") && !["加油站", "工作站", "氣象站", "天文站"].contains(where: text.hasSuffix)
    }
}

public struct PlaceMatcher: Sendable {
    private let input: SearchQuery
    public init(query: String, vocabulary: SearchVocabulary = SearchVocabulary()) { input = SearchQuery(query, vocabulary: vocabulary) }
    public func rank(name: String, address: String = "") -> Int? { StationSearch.placeRank(name: name, address: address, input: input) }
}

fileprivate struct SearchQuery: Sendable {
    let text: String
    let aliases: Set<String>
    let partial: [String]
    let tokens: [String]
    let addressLike: Bool
    let hasDigits: Bool
    let transit: Bool
    init(_ original: String, vocabulary: SearchVocabulary = SearchVocabulary()) {
        let query = StationSearch.cleanQuery(original)
        text = StationSearch.normalize(query)
        var names = StationSearch.aliases(query, normalized: text)
        for city in ["台北市", "新北市", "台北", "新北"] where text.hasPrefix(city) && text.count > city.count + 1 {
            names.formUnion(StationSearch.aliases(String(text.dropFirst(city.count))))
        }
        aliases = vocabulary.expand(names)
        let minimumLength = text.count == 1 ? 1 : 2
        partial = aliases.filter { !$0.allSatisfy(\.isNumber) && $0.count >= minimumLength }.sorted()
        addressLike = query.contains(where: { "路街段巷弄號号".contains($0) })
        hasDigits = query.contains(where: \.isNumber)
        transit = StationSearch.isTransitQuery(query) || (vocabulary.placeQueries(query)?.contains { StationSearch.isTransitQuery($0) } ?? false)
        let pieces = query.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，·")))
            .map(StationSearch.normalize).filter { !$0.isEmpty && !["捷運", "mrt", "站牌", "公車", "台北", "台北市", "新北市"].contains($0) }
        tokens = Array(Set(pieces))
    }
}

fileprivate struct IndexedName: Sendable {
    let full: String
    let aliases: Set<String>
    let metro: Bool
    init(_ name: String) {
        full = StationSearch.normalize(name)
        aliases = StationSearch.aliases(name, normalized: full)
        metro = full.hasPrefix("捷運") || full.hasPrefix("mrt")
    }
    func simpleRank(_ query: SearchQuery) -> Int? {
        guard !query.text.isEmpty else { return 0 }
        if full == query.text { return 0 }
        if !aliases.isDisjoint(with: query.aliases) { return query.transit && metro ? 0 : 1 }
        if query.partial.contains(where: { part in aliases.contains { $0.hasPrefix(part) } }) { return query.transit && !metro ? 3 : 2 }
        if query.partial.contains(where: { part in part.count >= 2 && aliases.contains { $0.contains(part) } }) { return query.transit && !metro ? 4 : 3 }
        if query.tokens.count > 1, query.tokens.allSatisfy({ part in aliases.contains { $0.contains(part) } }) { return 4 }
        return nil
    }
    func fuzzyRank(_ query: SearchQuery) -> Int? {
        var fuzzy: Int?
        for part in query.partial where (3...32).contains(part.count) {
            let small = Array(part)
            for value in aliases where value.count >= small.count - 1 && value.count <= small.count + 6 {
                let large = Array(value)
                var index = 0
                for letter in large where index < small.count { if small[index] == letter { index += 1 } }
                if index == small.count { fuzzy = min(fuzzy ?? 5, 5) }
                if abs(small.count - large.count) <= 1 && Self.oneEdit(small, large) {
                    let a = StationSearch.normalize(value.applyingTransform(.toLatin, reverse: false) ?? value)
                    let b = StationSearch.normalize(query.text.applyingTransform(.toLatin, reverse: false) ?? query.text)
                    if a == b { return 4 }
                    fuzzy = min(fuzzy ?? 6, 6)
                }
            }
        }
        return fuzzy
    }
    private static func oneEdit(_ a: [Character], _ b: [Character]) -> Bool {
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
}

/// Build off the UI actor. Common names and addresses are normalized only once.
public struct StationSearchIndex: Sendable {
    private struct Entry: Sendable {
        let station: Station
        let names: [IndexedName]
        let address: String
        let metro: Bool
    }
    private let entries: [Entry]
    public init(stations: [Station] = []) {
        var names: [String: IndexedName] = [:], addresses: [String: String] = [:]
        entries = stations.map { station in
            let indexed = Array(Set([station.name] + station.searchNames)).sorted().map { text -> IndexedName in
                if let existing = names[text] { return existing }
                let value = IndexedName(text); names[text] = value; return value
            }
            let address = addresses[station.address] ?? StationSearch.normalize(station.address)
            addresses[station.address] = address
            return Entry(station: station, names: indexed, address: address, metro: indexed.contains { $0.metro })
        }
    }
    public func search(_ query: String, near position: Coordinate, favorites: Set<String> = [], recent: [String] = [], limit: Int = 40,
                       vocabulary: SearchVocabulary = SearchVocabulary()) -> [Station] {
        guard limit > 0 else { return [] }
        let input = SearchQuery(query, vocabulary: vocabulary)
        var matches: [(station: Station, rank: Int, metro: Bool, distance: Double)] = []
        for entry in entries {
            var rank = entry.names.compactMap { $0.simpleRank(input) }.min()
            if rank == nil, !input.text.isEmpty, entry.address.contains(input.text) { rank = 4 }
            if rank == nil, input.addressLike, input.aliases.contains(where: { $0.count >= 2 && entry.address.contains($0) }) { rank = 4 }
            if rank == nil, input.tokens.count > 1, input.tokens.allSatisfy({ token in entry.address.contains(token) || entry.names.contains { $0.aliases.contains { $0.contains(token) } } }) { rank = 4 }
            if let rank { matches.append((entry.station, rank, entry.metro, entry.station.coordinate.distance(to: position))) }
        }
        // Exact/partial matches need no expensive phonetic matching against thousands of unrelated names.
        if matches.isEmpty, !input.text.isEmpty {
            for entry in entries {
                if let rank = entry.names.compactMap({ $0.fuzzyRank(input) }).min() {
                    matches.append((entry.station, rank, entry.metro, entry.station.coordinate.distance(to: position)))
                }
            }
        }
        var recentOrder: [String: Int] = [:]
        for (index, id) in recent.enumerated() where recentOrder[id] == nil { recentOrder[id] = index }
        return matches.sorted { a, b in
            if input.text.isEmpty {
                if favorites.contains(a.station.id) != favorites.contains(b.station.id) { return favorites.contains(a.station.id) }
                let ar = recentOrder[a.station.id] ?? Int.max, br = recentOrder[b.station.id] ?? Int.max
                if ar != br { return ar < br }
            } else if a.rank != b.rank { return a.rank < b.rank }
            if input.transit, a.metro != b.metro { return a.metro }
            return a.distance == b.distance ? a.station.id < b.station.id : a.distance < b.distance
        }.prefix(limit).map { $0.station }
    }
}
