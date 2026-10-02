import Foundation

/// Match familiar place names before proximity, while keeping physical platforms distinct.
public enum StationSearch {
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "zh_TW"))
            .replacingOccurrences(of: "臺", with: "台")
            .replacingOccurrences(of: "内", with: "內")
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func baseName(_ text: String) -> String {
        let value = text.components(separatedBy: CharacterSet(charactersIn: "(（")).first ?? text
        return normalize(value)
    }

    public static func rank(name: String, query: String) -> Int? {
        let value = normalize(name), text = normalize(query)
        guard !text.isEmpty else { return 0 }
        if value == text { return 0 }
        let base = baseName(name)
        if base == text { return 1 }
        if base.hasPrefix("捷運") {
            let familiar = String(base.dropFirst(2))
            if familiar == text || (familiar.hasSuffix("站") && String(familiar.dropLast()) == text) { return 1 }
        }
        if base.hasPrefix("mrt") {
            var english = String(base.dropFirst(3))
            if english.hasSuffix("station") { english = String(english.dropLast(7)) }
            else if english.hasSuffix("sta") { english = String(english.dropLast(3)) }
            if english == text { return 1 }
        }
        if value.hasPrefix(text) { return 2 }
        return value.contains(text) ? 3 : nil
    }

    public static func search(_ query: String, metadata: TransitMetadata, near position: Coordinate,
                              favorites: Set<String> = [], recent: [String] = [], limit: Int = 40) -> [Station] {
        let text = normalize(query)
        guard limit > 0 else { return [] }
        return metadata.stations.values.compactMap { station -> (Station, Int)? in
            let names = [station.name] + station.searchNames
            let ranks = names.compactMap { rank(name: $0, query: query) }
            if let rank = ranks.min() { return (station, rank) }
            return normalize(station.address).contains(text) ? (station, 4) : nil
        }.sorted { a, b in
            if text.isEmpty {
                if favorites.contains(a.0.id) != favorites.contains(b.0.id) { return favorites.contains(a.0.id) }
                let ar = recent.firstIndex(of: a.0.id) ?? Int.max, br = recent.firstIndex(of: b.0.id) ?? Int.max
                if ar != br { return ar < br }
            } else if a.1 != b.1 { return a.1 < b.1 }
            let ad = a.0.coordinate.distance(to: position), bd = b.0.coordinate.distance(to: position)
            return ad == bd ? a.0.id < b.0.id : ad < bd
        }.prefix(limit).map { $0.0 }
    }

    /// Add common, useful queries without inventing coordinates or treating a bus platform as a metro entrance.
    public static func placeQueries(_ query: String) -> [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let normalized = normalize(text)
        let aliases = ["北車": "臺北車站", "台大": "國立臺灣大學", "101": "臺北101"]
        if let alias = aliases[normalized] { return [alias, text] }
        if normalized.hasSuffix("站"), !normalized.hasPrefix("捷運"), !normalized.hasSuffix("車站") {
            return ["捷運" + text, text]
        }
        return [text]
    }
}
