import Foundation

public enum FeedError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let name): return "\(name)資料格式錯誤" }
    }
}

public enum FeedDecoder {
    public static func taipeiDate(_ value: String) -> Date? {
        taipeiDate(value, formatter: makeTaipeiFormatter())
    }

    private static func makeTaipeiFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }

    private static func taipeiDate(_ value: String, formatter: DateFormatter) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        if let date = formatter.date(from: text) { return date }
        let iso = ISO8601DateFormatter()
        return iso.date(from: text)
    }

    static func rows(_ data: Data) throws -> ([[String: Any]], Date?) {
        var bytes = data
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        let root = try JSONSerialization.jsonObject(with: bytes)
        if let array = root as? [[String: Any]] { return (array, nil) }
        guard let object = root as? [String: Any], let rows = object["BusInfo"] as? [[String: Any]] else {
            throw FeedError.invalid("公開來源")
        }
        let essential = object["EssentialInfo"] as? [String: Any]
        return (rows, (essential?["UpdateTime"] as? String).flatMap(taipeiDate))
    }

    static func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func number(_ value: Any?) -> Double? {
        guard let result = Double(text(value)), result.isFinite else { return nil }
        return result
    }

    public static func validateMetadataFeed(_ data: Data) throws {
        let (entries, _) = try rows(data)
        guard !entries.isEmpty else { throw FeedError.invalid("路線／站牌") }
    }

    public static func metadata(feeds: [String: Data]) throws -> TransitMetadata {
        var metadata = TransitMetadata()
        for (name, data) in feeds {
            let required = name == "GetRoute" || name == "GetStop"
            let decoded: ([[String: Any]], Date?)
            do { decoded = try rows(data) }
            catch { if required { throw error }; continue }
            let (rows, _) = decoded
            guard !rows.isEmpty else { if required { throw FeedError.invalid(name) }; continue }
            switch name {
            case "GetRoute":
                for row in rows {
                    let id = text(row["pathAttributeId"]), parent = text(row["Id"])
                    guard !id.isEmpty, !parent.isEmpty else { continue }
                    var route = BusRoute(id: id, parentID: parent, name: text(row["nameZh"]),
                                         variantName: text(row["pathAttributeName"]),
                                         departure: text(row["departureZh"]), destination: text(row["destinationZh"]))
                    route.englishName = text(row["nameEn"])
                    route.englishVariantName = text(row["pathAttributeEname"])
                    route.aliasName = text(row["aliasName"])
                    for (direction, prefix) in [("0", "go"), ("1", "back")] {
                        let holiday = "holiday" + prefix.prefix(1).uppercased() + String(prefix.dropFirst())
                        route.serviceWindows[direction] = [prefix, holiday].compactMap { key in
                            BusServiceWindow(first: text(row[key + "FirstBusTime"]), last: text(row[key + "LastBusTime"]))
                        }
                    }
                    metadata.routes[id] = route
                }
            case "GetStop":
                for row in rows {
                    let id = text(row["Id"])
                    guard !id.isEmpty, let lat = number(row["latitude"]), let lon = number(row["longitude"]) else { continue }
                    let coordinate = Coordinate(latitude: lat, longitude: lon)
                    guard coordinate.isInServiceArea else { continue }
                    let stationID = text(row["stopLocationId"]).isEmpty ? id : text(row["stopLocationId"])
                    let stop = BusStop(id: id, routeID: text(row["routeId"]), stationID: stationID,
                                       name: text(row["nameZh"]), direction: text(row["goBack"]),
                                       sequence: Int(number(row["seqNo"]) ?? 0), coordinate: coordinate)
                    metadata.stops[id] = stop
                    if metadata.stations[stationID] == nil {
                        metadata.stations[stationID] = Station(id: stationID, name: stop.name, coordinate: coordinate,
                                                               address: text(row["address"]), bearing: text(row["bearing"]), stopIDs: [])
                    }
                    metadata.stations[stationID]?.stopIDs.append(id)
                    for name in [stop.name, text(row["nameEn"])] where !name.isEmpty {
                        if metadata.stations[stationID]?.searchNames.contains(name) == false {
                            metadata.stations[stationID]?.searchNames.append(name)
                        }
                    }
                }
            case "GetProvider":
                for row in rows {
                    let id = text(row["id"]), name = text(row["nameZn"])
                    if !id.isEmpty && !name.isEmpty { metadata.providers[id] = name }
                }
            case "GetPathDetail":
                for row in rows {
                    let type = text(row["type"] ?? row["Type"])
                    guard type.isEmpty || type == "0" else { continue }
                    let id = text(row["pathAttributeId"] ?? row["PathAttributeId"])
                    let stopID = text(row["stopId"] ?? row["StopId"])
                    guard !id.isEmpty, !stopID.isEmpty else { continue }
                    metadata.paths[id, default: []].append(StopReference(stopID: stopID,
                        sequence: Int(number(row["sequenceNo"] ?? row["SequenceNo"]) ?? 0)))
                }
            case "GetBusShape":
                for row in rows {
                    guard let line = RouteLine.parse(wkt: text(row["wkt"])) else { continue }
                    let sub = text(row["SubRouteID"])
                    let key = (number(row["SubRouteID"]) ?? -1) > 0 ? "sub:\(sub)" : "route:\(text(row["RouteID"]))"
                    let direction = text(row["GoBack"])
                    if ["0", "1"].contains(direction) { metadata.directionalLines["\(key):\(direction)"] = line }
                    if metadata.lines[key] == nil || direction == "0" { metadata.lines[key] = line }
                }
            default: break
            }
        }
        guard !metadata.routes.isEmpty, !metadata.stations.isEmpty else { throw FeedError.invalid("路線／站牌") }
        metadata.rebuildRouteCatalog()
        metadata.stationSearch = StationSearchIndex(stations: Array(metadata.stations.values))
        metadata.rebuildJourneys()
        return metadata
    }

    public static func estimates(_ data: Data) throws -> EstimateFeed {
        let (rows, updatedAt) = try rows(data)
        guard !rows.isEmpty, let updatedAt else { throw FeedError.invalid("到站預估") }
        var values: [String: Int] = [:]
        for row in rows {
            guard let number = number(row["EstimateTime"]), abs(number) < 86_400 else { continue }
            values["\(text(row["RouteID"])):\(text(row["StopID"]))"] = Int(number)
        }
        return EstimateFeed(seconds: values, updatedAt: updatedAt)
    }

    public static func vehicles(_ data: Data, metadata: TransitMetadata,
                                previous: [BusVehicle], now: Date) throws -> (vehicles: [BusVehicle], updatedAt: Date?) {
        let (rows, updatedAt) = try rows(data)
        guard !rows.isEmpty, updatedAt != nil else { throw FeedError.invalid("車輛定位") }
        let prior = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.observedAt > b.observedAt ? a : b })
        let dateFormatter = makeTaipeiFormatter()
        var unique: [String: BusVehicle] = [:]
        var ended: [String: Date] = [:]
        for row in rows {
            let plate = text(row["BusID"]), routeID = text(row["RouteID"])
            let carID = text(row["CarID"]), id = carID.isEmpty ? plate : carID
            guard !plate.isEmpty, let date = taipeiDate(text(row["DataTime"]), formatter: dateFormatter),
                  (-60...900).contains(now.timeIntervalSince(date)) else { continue }
            if text(row["DutyStatus"]) == "2" || text(row["BusStatus"]) == "99" {
                if date >= (prior[id]?.observedAt ?? .distantPast) { ended[id] = max(ended[id] ?? .distantPast, date) }
                continue
            }
            guard let lat = number(row["Latitude"]), let lon = number(row["Longitude"]) else { continue }
            let coordinate = Coordinate(latitude: lat, longitude: lon)
            guard coordinate.isInServiceArea else { continue }
            if let other = unique[id], other.observedAt >= date { continue }
            let route = metadata.route(routeID), direction = text(row["GoBack"])
            let speed = number(row["Speed"]) ?? 0
            let heading = number(row["Azimuth"]) ?? 0
            var vehicle = BusVehicle(id: id, plate: plate, routeID: routeID, parentRouteID: route?.parentID ?? routeID,
                routeName: route?.variantName.isEmpty == false ? route!.variantName : route?.name ?? routeID,
                direction: direction, destination: route?.destination(direction: direction) ?? "方向未提供",
                coordinate: coordinate, rawCoordinate: coordinate,
                heading: (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360),
                speed: (0..<180).contains(speed) ? speed : 0, observedAt: date,
                status: text(row["BusStatus"]), lowFloor: text(row["CarType"]) == "1",
                provider: metadata.providers[text(row["ProviderID"])])
            vehicle.hasHeading = number(row["Azimuth"]).map { (0...360).contains($0) } ?? false
            vehicle.hasSpeed = number(row["Speed"]).map { (0..<180).contains($0) } ?? false
            unique[id] = vehicle
        }
        unique = unique.filter { id, vehicle in ended[id].map { $0 < vehicle.observedAt } ?? true }
        let accepted = unique.values.map { VehicleTracker.accept($0, previous: prior[$0.id], metadata: metadata, now: now) }
        let retired = Set(ended.keys.filter { unique[$0] == nil })
        let retained = VehicleTracker.retainMissing(previous: previous, current: accepted, ended: retired, now: now)
        return ((accepted + retained).sorted { $0.id < $1.id }, updatedAt)
    }
}
