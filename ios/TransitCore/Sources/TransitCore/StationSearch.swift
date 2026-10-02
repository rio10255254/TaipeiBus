import Foundation

public struct StationResultGroup: Identifiable, Sendable {
    public let name: String
    public let stations: [Station]
    public var id: String { name }
}

/// Shared text matching for station names and native place results. Proximity only breaks relevance ties.
public enum StationSearch {
    private static let familiarNames = [
        ["台北車站", "台北站", "北車", "Taipei Main Station"],
        ["台北101", "101", "Taipei 101", "台北101購物中心"],
        ["台大", "台灣大學", "國立台灣大學", "National Taiwan University", "NTU"],
        ["台大醫院", "國立台灣大學醫學院附設醫院", "National Taiwan University Hospital"],
        ["三總", "三軍總醫院", "Tri-Service General Hospital"],
        ["小巨蛋", "台北小巨蛋", "Taipei Arena"],
        ["榮總", "台北榮總", "台北榮民總醫院"],
        ["松山機場", "台北松山機場", "Taipei Songshan Airport"]
    ]
    private static let queryNames: [String: [String]] = [
        "台北101": ["Taipei 101", "台北101"], "101": ["Taipei 101", "台北101"],
        "台大": ["國立台灣大學", "National Taiwan University"], "ntu": ["National Taiwan University", "國立台灣大學"],
        "北車": ["台北車站", "Taipei Main Station"], "三總": ["三軍總醫院", "Tri-Service General Hospital"],
        "小巨蛋": ["台北小巨蛋", "Taipei Arena"], "榮總": ["台北榮民總醫院"]
    ]
    private static let familiarAliases = familiarNames.map { Set($0.map(normalize)) }

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
    fileprivate static func aliases(_ text: String) -> Set<String> {
        let full = normalize(text), base = normalize(baseName(text))
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
        if base.hasPrefix("mrt") {
            var english = String(base.dropFirst(3))
            if english.hasSuffix("station") { english = String(english.dropLast(7)) }
            else if english.hasSuffix("sta") { english = String(english.dropLast(3)) }
            values.insert(english)
        }
        for names in familiarAliases {
            if !values.isDisjoint(with: names) { values.formUnion(names) }
        }
        values.remove("")
        return values
    }
    public static func rank(name: String, query: String) -> Int? {
        IndexedName(name).rank(SearchQuery(query))
    }
    public static func placeRank(name: String, address: String, query: String) -> Int? {
        let input = SearchQuery(query)
        if let rank = IndexedName(name).rank(input) { return rank }
        guard input.addressLike || !input.hasDigits else { return nil }
        let address = normalize(address)
        if input.aliases.contains(where: { $0.count >= 2 && address.contains($0) }), input.addressLike { return 4 }
        if address.contains(input.text), !input.text.isEmpty { return 4 }
        if input.tokens.count > 1, input.tokens.allSatisfy({ normalize(name).contains($0) || address.contains($0) }) { return 4 }
        return nil
    }
    public static func search(_ query: String, metadata: TransitMetadata, near position: Coordinate,
                              favorites: Set<String> = [], recent: [String] = [], limit: Int = 40) -> [Station] {
        StationSearchIndex(stations: Array(metadata.stations.values)).search(query, near: position, favorites: favorites, recent: recent, limit: limit)
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
    public static func placeQueries(_ query: String) -> [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let normalized = normalize(text)
        if let aliases = queryNames[normalized] { return Array((aliases + [text]).prefix(3)) }
        let traditional = text.applyingTransform(StringTransform(rawValue: "Simplified-Traditional"), reverse: false) ?? text
        let standard = traditional.replacingOccurrences(of: "臺", with: "台")
        if normalized.hasSuffix("站"), !normalized.hasPrefix("捷運"), !normalized.hasSuffix("車站"), !normalized.hasSuffix("捷運站") {
            return ["捷運" + standard, standard]
        }
        return standard == text ? [text] : [standard, text]
    }
    public static func isAddressQuery(_ query: String) -> Bool { SearchQuery(query).addressLike }
    public static func isTransitQuery(_ query: String) -> Bool {
        let text = normalize(query)
        if text.contains("捷運") || text.hasPrefix("mrt") { return true }
        return text.hasSuffix("站") && !["加油站", "工作站", "氣象站", "天文站"].contains(where: text.hasSuffix)
    }
}

fileprivate struct SearchQuery {
    let text: String
    let aliases: Set<String>
    let tokens: [String]
    let addressLike: Bool
    let hasDigits: Bool
    let latin: String
    let transit: Bool
    init(_ query: String) {
        text = StationSearch.normalize(query)
        var names = StationSearch.aliases(query)
        for city in ["台北市", "新北市", "台北", "新北"] where text.hasPrefix(city) && text.count > city.count + 1 {
            names.formUnion(StationSearch.aliases(String(text.dropFirst(city.count))))
        }
        aliases = names
        addressLike = query.contains(where: { "路街段巷弄號号".contains($0) })
        hasDigits = query.contains(where: \.isNumber)
        latin = StationSearch.normalize(query.applyingTransform(.toLatin, reverse: false) ?? query)
        transit = StationSearch.isTransitQuery(query)
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
        full = StationSearch.normalize(name); aliases = StationSearch.aliases(name)
        metro = full.hasPrefix("捷運") || full.hasPrefix("mrt")
    }
    func rank(_ query: SearchQuery) -> Int? {
        guard !query.text.isEmpty else { return 0 }
        if full == query.text { return 0 }
        if !aliases.isDisjoint(with: query.aliases) { return query.transit && metro ? 0 : 1 }
        let partial = query.aliases.filter { !$0.allSatisfy(\.isNumber) && $0.count >= 2 }
        if partial.contains(where: { part in aliases.contains { $0.hasPrefix(part) } }) { return query.transit && !metro ? 3 : 2 }
        if partial.contains(where: { part in aliases.contains { $0.contains(part) } }) { return query.transit && !metro ? 4 : 3 }
        if query.tokens.count > 1, query.tokens.allSatisfy({ part in aliases.contains { $0.contains(part) } }) { return 4 }
        // One-character mistakes and abbreviated Chinese names are lower-priority alternatives, never promoted above exact names.
        var fuzzy: Int?
        for part in partial where part.count >= 3 {
            for value in aliases where value.count >= part.count - 1 && value.count <= part.count + 6 {
                let small = Array(part), large = Array(value)
                var index = 0
                for letter in large where index < small.count { if small[index] == letter { index += 1 } }
                if index == small.count && small.count >= 3 { fuzzy = min(fuzzy ?? 5, 5) }
                if abs(small.count - large.count) <= 1 && Self.oneEdit(small, large) {
                    if StationSearch.normalize(value.applyingTransform(.toLatin, reverse: false) ?? value) == query.latin { return 4 }
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

/// Build once with metadata, off the UI actor, instead of converting every station name on every keystroke.
public struct StationSearchIndex: Sendable {
    private struct Entry: Sendable {
        let station: Station
        let names: [IndexedName]
        let address: String
    }
    private let entries: [Entry]
    public init(stations: [Station] = []) {
        entries = stations.map { Entry(station: $0, names: ([$0.name] + $0.searchNames).map(IndexedName.init), address: StationSearch.normalize($0.address)) }
    }
    public func search(_ query: String, near position: Coordinate, favorites: Set<String> = [], recent: [String] = [], limit: Int = 40) -> [Station] {
        guard limit > 0 else { return [] }
        let input = SearchQuery(query)
        return entries.compactMap { entry -> (Station, Int, Bool)? in
            let metro = entry.names.contains { $0.metro }
            if let rank = entry.names.compactMap({ $0.rank(input) }).min() { return (entry.station, rank, metro) }
            if !input.text.isEmpty, entry.address.contains(input.text) { return (entry.station, 4, metro) }
            if input.addressLike, input.aliases.contains(where: { $0.count >= 2 && entry.address.contains($0) }) { return (entry.station, 4, metro) }
            if input.tokens.count > 1, input.tokens.allSatisfy({ token in entry.address.contains(token) || entry.names.contains { $0.aliases.contains { $0.contains(token) } } }) { return (entry.station, 4, metro) }
            return nil
        }.sorted { a, b in
            if input.text.isEmpty {
                if favorites.contains(a.0.id) != favorites.contains(b.0.id) { return favorites.contains(a.0.id) }
                let ar = recent.firstIndex(of: a.0.id) ?? Int.max, br = recent.firstIndex(of: b.0.id) ?? Int.max
                if ar != br { return ar < br }
            } else if a.1 != b.1 { return a.1 < b.1 }
            if input.transit, a.2 != b.2 { return a.2 }
            let ad = a.0.coordinate.distance(to: position), bd = b.0.coordinate.distance(to: position)
            return ad == bd ? a.0.id < b.0.id : ad < bd
        }.prefix(limit).map { $0.0 }
    }
}
