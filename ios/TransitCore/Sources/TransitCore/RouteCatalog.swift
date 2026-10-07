import Foundation

public struct RouteGroup: Identifiable, Sendable {
    public var id: String { route.parentID }
    public let route: BusRoute
    public let variants: [BusRoute]
}

public struct RouteSearchResult: Identifiable, Sendable {
    public var id: String { group.id }
    public let group: RouteGroup
    public let matchedVariant: BusRoute?
    public var route: BusRoute { matchedVariant ?? group.route }
    public var name: String { matchedVariant?.displayName ?? group.route.name }
    public var localizedName: String { matchedVariant?.localizedDisplayName ?? group.route.localizedName }
}

/// A complete, stable catalog built once per metadata update, independent of live vehicle availability.
public struct RouteCatalog: Sendable {
    public let groups: [RouteGroup]
    private let groupsByID: [String: RouteGroup]
    private let entries: [Entry]

    private struct Entry: Sendable {
        let group: RouteGroup
        let names: [String]
        let destinations: [String]
        let variants: [(route: BusRoute, names: [String])]
    }

    public init(routes: [BusRoute] = []) {
        let orderedGroups = Dictionary(grouping: routes, by: \.parentID).values.map { rows in
            let variants = rows.sorted { a, b in
                let aBase = a.variantName.isEmpty || a.variantName == a.name
                let bBase = b.variantName.isEmpty || b.variantName == b.name
                if aBase != bBase { return aBase }
                if (a.id == a.parentID) != (b.id == b.parentID) { return a.id == a.parentID }
                let order = a.displayName.localizedStandardCompare(b.displayName)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
            return RouteGroup(route: variants[0], variants: variants)
        }.sorted { a, b in
            let order = a.route.name.localizedStandardCompare(b.route.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        groups = orderedGroups
        groupsByID = Dictionary(uniqueKeysWithValues: orderedGroups.map { ($0.id, $0) })
        entries = orderedGroups.map { group in
            Entry(group: group,
                  names: Array(Set(group.variants.flatMap { [$0.name, $0.englishName, $0.aliasName, $0.lineCode] }
                    .flatMap(Self.searchNames).filter { !$0.isEmpty })),
                  destinations: Array(Set(group.variants.flatMap { [$0.departure, $0.destination, $0.englishDeparture, $0.englishDestination] }
                    .map(Self.normalize).filter { !$0.isEmpty })),
                  variants: group.variants.map { ($0, [$0.displayName, $0.englishVariantName]
                    .flatMap(Self.searchNames).filter { !$0.isEmpty }) })
        }
    }

    public func group(parentID: String) -> RouteGroup? { groupsByID[parentID] }

    public func search(_ query: String) -> [RouteSearchResult] {
        let text = Self.normalize(query)
        guard !text.isEmpty else { return groups.map { RouteSearchResult(group: $0, matchedVariant: nil) } }
        // Exact names precede partial names and endpoints. Catalog order breaks all ties.
        return entries.enumerated().compactMap { index, entry -> (Int, Int, RouteSearchResult)? in
            let exactName = entry.names.contains(text)
            let partialName = entry.names.contains { $0.contains(text) }
            let exactVariant = entry.variants.first { $0.names.contains(text) }?.route
            let partialVariant = entry.variants.first { $0.names.contains { $0.contains(text) } }?.route
            let endpoint = entry.destinations.contains { $0.contains(text) }
            guard partialName || partialVariant != nil || endpoint else { return nil }
            let variant = partialName ? nil : exactVariant ?? partialVariant
            let rank = exactName ? 0 : exactVariant != nil ? 1 : partialName ? 2 : partialVariant != nil ? 3 : 4
            return (rank, index, RouteSearchResult(group: entry.group, matchedVariant: variant))
        }.sorted { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }.map { $0.2 }
    }

    private static func normalize(_ value: String) -> String {
        let name = value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "zh_TW"))
            .replacingOccurrences(of: "臺", with: "台")
            .filter { !$0.isWhitespace }
        // Localized keypad tokens still address the same canonical route names.
        for (english, chinese) in [("neihutech", "內科"), ("nangangsw", "南軟"), ("civic", "市民"),
            ("huai-en", "懷恩"), ("maokong", "貓空"), ("minibus", "小"), ("metrobus", "幹線"),
            ("red", "紅"), ("blue", "藍"), ("brown", "棕"), ("green", "綠"), ("orange", "橘"), ("yellow", "黃")] {
            if name.hasPrefix(english) {
                let suffix = String(name.dropFirst(english.count))
                if suffix.isEmpty || suffix.allSatisfy(\.isNumber) { return chinese + suffix }
            }
        }
        return name
    }
    private static func searchNames(_ value: String) -> [String] {
        let name = normalize(value)
        let compact = name.replacingOccurrences(of: "通勤專車", with: "").replacingOccurrences(of: "專車", with: "")
        return compact == name ? [name] : [name, compact]
    }
}

public struct RouteVehicleCounts: Sendable {
    private var parents: [String: Int] = [:]
    private var variants: [String: Int] = [:]
    public init(vehicles: [BusVehicle], at date: Date) {
        for bus in vehicles where bus.hasReliablePosition(at: date) {
            parents[bus.parentRouteID, default: 0] += 1
            variants[bus.routeID, default: 0] += 1
        }
    }
    public func count(route: BusRoute, allVariants: Bool) -> Int {
        (allVariants ? parents[route.parentID] : variants[route.id]) ?? 0
    }
}

public extension TransitMetadata {
    mutating func rebuildRouteCatalog() {
        routeCatalog = RouteCatalog(routes: Array(routes.values))
        parents = Dictionary(uniqueKeysWithValues: routeCatalog.groups.map { ($0.id, $0.route) })
    }

    func variants(routeID: String) -> [BusRoute] {
        guard let route = route(routeID) else { return [] }
        return routeCatalog.group(parentID: route.parentID)?.variants ?? [route]
    }

    func directions(routeID: String, allVariants: Bool) -> [String] {
        let options = allVariants ? variants(routeID: routeID) : route(routeID).map { [$0] } ?? []
        let available = ["0", "1"].filter { direction in
            options.contains { !orderedStops(routeID: $0.id, direction: direction).isEmpty }
        }
        return available.isEmpty ? ["0", "1"] : available
    }

    func vehicles(routeID: String, direction: String, allVariants: Bool, in vehicles: [BusVehicle]) -> [BusVehicle] {
        guard let route = route(routeID) else { return [] }
        return vehicles.filter { bus in
            bus.direction == direction && (allVariants ? bus.parentRouteID == route.parentID : bus.routeID == route.id)
        }.sorted { a, b in a.observedAt == b.observedAt ? a.id < b.id : a.observedAt > b.observedAt }
    }

    /// A parent view uses the base path, or the longest available path for this direction.
    /// Distinct branches are never joined into a fabricated stop sequence.
    func displayStops(routeID: String, direction: String, allVariants: Bool) -> [BusStop] {
        let selected = orderedStops(routeID: routeID, direction: direction)
        guard allVariants else { return selected }
        if let route = route(routeID), route.variantName.isEmpty || route.variantName == route.name, !selected.isEmpty {
            return selected
        }
        return variants(routeID: routeID).map { orderedStops(routeID: $0.id, direction: direction) }
            .max(by: { $0.count < $1.count }) ?? selected
    }

    func displayPaths(routeID: String, direction: String, allVariants: Bool) -> [[Coordinate]] {
        let options = allVariants ? variants(routeID: routeID) : route(routeID).map { [$0] } ?? []
        var seen = Set<[Coordinate]>()
        return options.compactMap { variant in
            if let references = paths[variant.id], !references.isEmpty,
               orderedStops(routeID: variant.id, direction: direction).isEmpty { return nil }
            guard let line = line(variant.id, direction: direction) else { return nil }
            let coordinates = journey(routeID: variant.id, direction: direction)?.coordinates(on: line) ?? line.coordinates
            guard coordinates.count >= 2, seen.insert(coordinates).inserted else { return nil }
            return coordinates
        }
    }
}
