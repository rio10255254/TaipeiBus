import Foundation
import TransitCore

/// Replays one recording (tools/arrival-benchmark/collect.py) through the App's own feed decoder,
/// vehicle tracker and VehicleArrivalForecast, poll by poll, then compares every prediction with
/// the moment the same bus actually reached that stop later in the recording.
///
/// Usage: ArrivalReplay --static DIR --official FILE --run DIR --out DIR [--every N]
///
/// Writes to --out:
/// - predictions.csv.gz  one row per (poll, bus, downstream sampled stop) the App could be asked about
/// - official.csv.gz     one row per official EstimateTime (route/stop) with the next actual arrival
/// - summary.json        counts for checking coverage of the replay itself

struct Options {
    var staticFolder = ""
    var official = ""
    var run = ""
    var out = ""
    /// Predict on every Nth poll. The recorder polls every 20 s, so 3 means once a minute per bus.
    var every = 3
    /// How many stops ahead of a bus are evaluated.
    var maxStopsAhead = 40

    init(_ arguments: [String]) {
        var index = 1
        func value() -> String {
            index += 1
            guard index < arguments.count else { fail("missing value for \(arguments[index - 1])") }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--static": staticFolder = value()
            case "--official": official = value()
            case "--run": run = value()
            case "--out": out = value()
            case "--every": every = max(1, Int(value()) ?? 3)
            case "--max-stops-ahead": maxStopsAhead = max(1, Int(value()) ?? 40)
            default: fail("unknown argument \(arguments[index])")
            }
            index += 1
        }
        if staticFolder.isEmpty || official.isEmpty || run.isEmpty || out.isEmpty {
            fail("usage: ArrivalReplay --static DIR --official FILE --run DIR --out DIR [--every N]")
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - gzip through the system tool (no zlib binding needed on Linux or macOS)

func gunzip(_ path: String) -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gzip", "-dc", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { fail("cannot run gzip: \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("gzip failed for \(path)") }
    return data
}

/// Streams the lines of a .csv.gz without holding the whole file as one String.
func forEachLine(ofGzip path: String, _ body: (Substring) -> Void) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gzip", "-dc", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { fail("cannot run gzip: \(error)") }
    let handle = pipe.fileHandleForReading
    // Python's csv module ends lines with CRLF, which Swift's String treats as one Character,
    // so lines are split on bytes and a trailing CR is dropped.
    func emit(_ bytes: Data) {
        for line in bytes.split(separator: 0x0a, omittingEmptySubsequences: true) {
            let text = String(decoding: line.last == 0x0d ? line.dropLast() : line, as: UTF8.self)
            if !text.isEmpty { body(Substring(text)) }
        }
    }
    var buffer = Data()
    while true {
        let chunk = handle.readData(ofLength: 1 << 20)
        if chunk.isEmpty { break }
        buffer.append(chunk)
        guard let last = buffer.lastIndex(of: 0x0a) else { continue }
        emit(buffer[buffer.startIndex...last])
        buffer = Data(buffer[buffer.index(after: last)...])
    }
    emit(buffer)
    process.waitUntilExit()
}

final class GzipWriter {
    private let process = Process()
    private let pipe = Pipe()
    private var pending = ""

    init(_ path: String, header: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: path) else { fail("cannot write \(path)") }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gzip", "-c"]
        process.standardInput = pipe
        process.standardOutput = output
        do { try process.run() } catch { fail("cannot run gzip: \(error)") }
        write(header)
    }
    func write(_ line: String) {
        pending += line; pending += "\n"
        if pending.utf8.count > 1 << 20 { flush() }
    }
    private func flush() {
        pipe.fileHandleForWriting.write(Data(pending.utf8)); pending = ""
    }
    func close() {
        flush()
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

// MARK: - Inputs

let options = Options(CommandLine.arguments)
let isoFormatter = ISO8601DateFormatter()

func loadMetadata() -> TransitMetadata {
    var feeds: [String: Data] = [:]
    for name in ["GetRoute", "GetStop", "GetPathDetail", "GetBusShape"] {
        let path = options.staticFolder + "/" + name + ".gz"
        guard FileManager.default.fileExists(atPath: path) else { fail("missing \(path)") }
        feeds[name] = gunzip(path)
    }
    do {
        var metadata = try FeedDecoder.metadata(feeds: feeds)
        guard let bytes = FileManager.default.contents(atPath: options.official) else { fail("missing \(options.official)") }
        metadata.officialTravelTimes = try OfficialTravelTimes(data: bytes).matching(metadata)
        return metadata
    } catch { fail("cannot decode static feeds: \(error)") }
}

/// Official route/stop estimates as the App held them: one EstimateFeed per poll, valid from its received time.
struct OfficialPoll {
    let received: Date
    let feed: EstimateFeed
    /// (routeID, stopID, goBack, seconds) for scoring; negative status codes are kept out.
    let rows: [(String, String, String, Int)]
}

func loadOfficial() -> (polls: [OfficialPoll], stops: Set<String>) {
    var polls: [OfficialPoll] = []
    var stops: Set<String> = []
    var currentReceived = "", currentUpdate = ""
    var seconds: [String: Int] = [:]
    var rows: [(String, String, String, Int)] = []
    func finish() {
        guard !currentReceived.isEmpty, let received = isoFormatter.date(from: currentReceived),
              let updated = FeedDecoder.taipeiDate(currentUpdate) else { return }
        polls.append(OfficialPoll(received: received, feed: EstimateFeed(seconds: seconds, updatedAt: updated), rows: rows))
    }
    var header = true
    forEachLine(ofGzip: options.run + "/eta.csv.gz") { line in
        if header { header = false; return }
        let field = line.split(separator: ",", omittingEmptySubsequences: false)
        guard field.count >= 6 else { return }
        let received = String(field[0])
        if received != currentReceived {
            finish()
            currentReceived = received; currentUpdate = String(field[1]); seconds = [:]; rows = []
        }
        let route = String(field[2]), stop = String(field[3]), goBack = String(field[4])
        guard let value = Int(field[5]) ?? Double(field[5]).map({ Int($0) }), abs(value) < 86_400 else { return }
        stops.insert(stop)
        seconds["\(route):\(stop)"] = value
        if value >= 0 { rows.append((route, stop, goBack, value)) }
    }
    finish()
    return (polls, stops)
}

let started = Date()
let metadata = loadMetadata()
let (officialPolls, sampledStops) = loadOfficial()
FileHandle.standardError.write(Data("metadata: \(metadata.routes.count) routes, \(metadata.stops.count) stops; official polls \(officialPolls.count), sampled stops \(sampledStops.count)\n".utf8))

// MARK: - Ground truth: when each bus actually reached each stop

/// A stop is "reached" when the bus comes within this distance before it along the route shape,
/// the moment a waiting rider sees it pull in. Passing the stop itself is recorded too.
let arrivalLead = 30.0
/// Interpolate only between reports at most this far apart; the gap is kept as the truth's uncertainty.
let maximumBracket = 120.0

struct Crossing { var arrive: Double?; var arriveBracket: Double?; var pass: Double?; var passBracket: Double? }
struct TrackState { var route: String; var direction: String; var along: Double; var date: Date; var trip: Int }

var tracks: [String: TrackState] = [:]
var tripCounter: [String: Int] = [:]
/// "vehicle|trip|stop" → crossing times.
var crossings: [String: Crossing] = [:]
/// "parentRoute|stop" → every crossing at that stop, for the official next-bus truth.
var stopCrossings: [String: [(vehicle: String, arrive: Double?, pass: Double)]] = [:]

func observeCrossings(_ vehicles: [BusVehicle], at now: Date) {
    for bus in vehicles {
        guard bus.hasReliablePosition(at: now), bus.aligned, let match = bus.roadMatch,
              let journey = metadata.journey(routeID: bus.routeID, direction: bus.direction) else { continue }
        let along = match.along * Double(journey.direction)
        let previous = tracks[bus.id]
        if let previous, bus.observedAt <= previous.date { continue }
        var trip = previous?.trip ?? 0
        var sameTrip = false
        if let previous, previous.route == bus.routeID, previous.direction == bus.direction,
           bus.observedAt.timeIntervalSince(previous.date) <= 300, along >= previous.along - 200 {
            sameTrip = true
        } else {
            trip = (tripCounter[bus.id] ?? 0) + 1; tripCounter[bus.id] = trip
        }
        if sameTrip, let previous {
            let interval = bus.observedAt.timeIntervalSince(previous.date), moved = along - previous.along
            if interval <= maximumBracket, moved > 2, moved / interval <= 25 {
                for anchor in journey.anchors {
                    let point = anchor.match.along * Double(journey.direction)
                    let key = "\(bus.id)|\(trip)|\(anchor.stop.id)"
                    func time(at target: Double) -> Double {
                        previous.date.timeIntervalSince1970 + interval * (target - previous.along) / moved
                    }
                    let arrivePoint = point - arrivalLead
                    if arrivePoint > previous.along, arrivePoint <= along, crossings[key]?.arrive == nil {
                        crossings[key, default: Crossing()].arrive = time(at: arrivePoint)
                        crossings[key]?.arriveBracket = interval
                    }
                    if point > previous.along, point <= along, crossings[key]?.pass == nil {
                        let passed = time(at: point)
                        crossings[key, default: Crossing()].pass = passed
                        crossings[key]?.passBracket = interval
                        stopCrossings["\(bus.parentRouteID)|\(anchor.stop.id)", default: []]
                            .append((bus.id, crossings[key]?.arrive, passed))
                    }
                }
            }
        }
        tracks[bus.id] = TrackState(route: bus.routeID, direction: bus.direction, along: along, date: bus.observedAt, trip: trip)
    }
}

// MARK: - Predictions as the App would show them

struct PredictionRow {
    let madeAt: Double
    let vehicle: String
    let trip: Int
    let route: String
    let parent: String
    let direction: String
    let stop: String
    let stopsAhead: Int
    let distance: Double
    let prediction: VehicleArrivalPrediction?
    let shown: Bool
    let age: Double
    let official: Int?
    let speed: Double
}

var predictions: [PredictionRow] = []
predictions.reserveCapacity(4_000_000)

// MARK: - Replay

var forecast = VehicleArrivalForecast()
var previousVehicles: [BusVehicle] = []
/// The latest report of each bus, as the public feed would list it at a poll.
var latestRows: [String: [String: Any]] = [:]
var officialIndex = 0
var currentOfficial: EstimateFeed?
var pollCount = 0, decodeErrors = 0, firstPoll: Date?, lastPoll: Date?
let gpsFields = ["BusID", "CarID", "RouteID", "GoBack", "Longitude", "Latitude", "Speed", "Azimuth", "DataTime", "DutyStatus", "BusStatus", "ProviderID"]
let taipei: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

func processPoll(_ received: String) {
    guard let now = isoFormatter.date(from: received) else { return }
    pollCount += 1
    firstPoll = firstPoll ?? now; lastPoll = now
    while officialIndex < officialPolls.count, officialPolls[officialIndex].received <= now {
        currentOfficial = officialPolls[officialIndex].feed; officialIndex += 1
    }
    let rows = Array(latestRows.values)
    let update = taipei.string(from: now)
    guard let data = try? JSONSerialization.data(withJSONObject: ["BusInfo": rows, "EssentialInfo": ["UpdateTime": update]]),
          let result = try? FeedDecoder.vehicles(data, metadata: metadata, previous: previousVehicles, now: now) else {
        decodeErrors += 1; return
    }
    previousVehicles = result.vehicles
    // The App ingests each snapshot with the time it arrived.
    forecast.ingest(result.vehicles, metadata: metadata, at: now)
    observeCrossings(result.vehicles, at: now)
    guard pollCount % options.every == 0 else { return }
    for bus in result.vehicles {
        guard bus.hasReliablePosition(at: now), let journey = metadata.journey(routeID: bus.routeID, direction: bus.direction),
              let trip = tracks[bus.id]?.trip else { continue }
        let upcoming = journey.upcoming(vehicle: bus, at: now)
        for (index, progress) in upcoming.prefix(options.maxStopsAhead).enumerated() where sampledStops.contains(progress.stop.id) {
            let official = currentOfficial?.value(routeID: bus.parentRouteID, stopID: progress.stop.id, at: now)
            let prediction = forecast.prediction(bus, stopID: progress.stop.id, metadata: metadata, at: now)
            let display = forecast.display(bus, stopID: progress.stop.id, metadata: metadata, at: now, officialSeconds: official)
            predictions.append(PredictionRow(madeAt: now.timeIntervalSince1970, vehicle: bus.id, trip: trip,
                route: bus.routeID, parent: bus.parentRouteID, direction: bus.direction, stop: progress.stop.id,
                stopsAhead: index + 1, distance: progress.distance, prediction: prediction,
                shown: display.prediction.map { !$0.nearStop } ?? false,
                age: now.timeIntervalSince(bus.observedAt), official: official, speed: bus.hasSpeed ? bus.speed : -1))
        }
    }
    if pollCount % 180 == 0 {
        FileHandle.standardError.write(Data("\(received) polls \(pollCount) vehicles \(result.vehicles.count) predictions \(predictions.count)\n".utf8))
    }
}

var currentReceived = ""
var header = true
forEachLine(ofGzip: options.run + "/gps.csv.gz") { line in
    if header { header = false; return }
    let field = line.split(separator: ",", omittingEmptySubsequences: false)
    guard field.count == gpsFields.count + 1 else { return }
    let received = String(field[0])
    if received != currentReceived {
        if !currentReceived.isEmpty { processPoll(currentReceived) }
        currentReceived = received
    }
    var row: [String: Any] = [:]
    for (index, name) in gpsFields.enumerated() { row[name] = String(field[index + 1]) }
    let id = (row["CarID"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (row["BusID"] as? String ?? "")
    guard !id.isEmpty else { return }
    latestRows[id] = row
    // The public feed drops a bus some minutes after its last report; FeedDecoder ignores older ones anyway.
}
if !currentReceived.isEmpty { processPoll(currentReceived) }

// MARK: - Output

try? FileManager.default.createDirectory(atPath: options.out, withIntermediateDirectories: true)
func format(_ value: Double?, _ digits: Int = 0) -> String {
    guard let value, value.isFinite else { return "" }
    return digits == 0 ? String(Int(value.rounded())) : String(format: "%.\(digits)f", value)
}

let predictionWriter = GzipWriter(options.out + "/predictions.csv.gz", header:
    "made_at,vehicle,route,parent,direction,stop,stops_ahead,distance_m,speed_kmh,age_s,evidence,predicted_s,uncertainty_s,usable,near_stop,shown,official_s,actual_arrive_s,arrive_bracket_s,actual_pass_s,pass_bracket_s")
var matched = 0
for row in predictions {
    let crossing = crossings["\(row.vehicle)|\(row.trip)|\(row.stop)"]
    let arrive = crossing?.arrive.flatMap { $0 >= row.madeAt - 30 ? $0 - row.madeAt : nil }
    let pass = crossing?.pass.flatMap { $0 >= row.madeAt - 30 ? $0 - row.madeAt : nil }
    if arrive != nil || pass != nil { matched += 1 }
    let prediction = row.prediction
    predictionWriter.write([
        format(row.madeAt), row.vehicle, row.route, row.parent, row.direction, row.stop, String(row.stopsAhead),
        format(row.distance), format(row.speed >= 0 ? row.speed : nil), format(row.age),
        prediction?.evidence.rawValue ?? "", format(prediction?.seconds), format(prediction?.uncertaintySeconds),
        prediction.map { $0.hasUsableTime ? "1" : "0" } ?? "", prediction.map { $0.nearStop ? "1" : "0" } ?? "",
        row.shown ? "1" : "0", row.official.map(String.init) ?? "",
        format(arrive), format(arrive == nil ? nil : crossing?.arriveBracket), format(pass), format(pass == nil ? nil : crossing?.passBracket)
    ].joined(separator: ","))
}
predictionWriter.close()

// Official estimates: the next bus of that route to pass the stop after the source time.
for key in stopCrossings.keys { stopCrossings[key]?.sort { $0.pass < $1.pass } }
let officialWriter = GzipWriter(options.out + "/official.csv.gz", header:
    "made_at,source_update,route,stop,direction,official_s,actual_arrive_s,actual_pass_s,vehicle")
var officialRows = 0, officialMatched = 0
let recordingEnd = lastPoll?.timeIntervalSince1970 ?? 0
for poll in officialPolls {
    guard let updated = poll.feed.updatedAt?.timeIntervalSince1970 else { continue }
    for (route, stop, goBack, seconds) in poll.rows {
        officialRows += 1
        let next = stopCrossings["\(route)|\(stop)"]?.first { $0.pass >= updated }
        if next != nil { officialMatched += 1 }
        // Without a later crossing inside the recording the truth is unknown, not "never".
        let arrive = next.map { max(0, ($0.arrive ?? $0.pass) - updated) }
        officialWriter.write([format(poll.received.timeIntervalSince1970), format(updated), route, stop, goBack, String(seconds),
                              format(arrive), format(next.map { $0.pass - updated }), next?.vehicle ?? ""].joined(separator: ","))
    }
}
officialWriter.close()

let summary: [String: Any] = [
    "run": options.run, "polls": pollCount, "decodeErrors": decodeErrors,
    "firstPoll": firstPoll.map { isoFormatter.string(from: $0) } ?? "", "lastPoll": lastPoll.map { isoFormatter.string(from: $0) } ?? "",
    "recordingEnd": recordingEnd,
    "predictionRows": predictions.count, "predictionRowsWithActual": matched,
    "crossings": crossings.count, "officialRows": officialRows, "officialRowsWithActual": officialMatched,
    "sampledStops": sampledStops.count, "seconds": Int(Date().timeIntervalSince(started))
]
if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
    FileManager.default.createFile(atPath: options.out + "/summary.json", contents: data)
    FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8))
}
