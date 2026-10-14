import XCTest
@testable import TransitCore

final class MetroTrainTrackerTests: XCTestCase {
    private func network() throws -> MetroNetwork {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try MetroNetwork(data: Data(contentsOf: root.appendingPathComponent("TaipeiBus/MetroNetwork.json")))
    }
    private func bannan(_ metro: MetroNetwork) throws -> MetroPattern {
        try XCTUnwrap(metro.patterns.first { $0.id == "metro:TRTC:BL-1" && $0.direction == "0" })
    }
    private func event(_ pattern: MetroPattern, _ index: Int, _ date: Date) -> MetroPlatformEvent {
        MetroPlatformEvent(stationID: pattern.stationIDs[index], patternID: pattern.id, direction: pattern.direction, observedAt: date)
    }
    /// When a train that left `index` at `departure` should enter `target`.
    private func arrival(_ pattern: MetroPattern, from index: Int, departure: Date, to target: Int) -> Date {
        var time = departure
        for hop in index..<target {
            time += MetroTrainTimeline.run(pattern, hop)
            if hop + 1 < target { time += MetroTrainTimeline.dwell(pattern, hop + 1) }
        }
        return time
    }

    func testEveryPatternHasOrderedStationsOnItsTrack() throws {
        let metro = try network()
        for pattern in metro.patterns {
            let geometry = try XCTUnwrap(MetroPatternGeometry(pattern: pattern), "\(pattern.id) \(pattern.direction)")
            XCTAssertEqual(geometry.stationAlong.count, pattern.stationIDs.count)
            XCTAssertEqual(geometry.stationAlong, geometry.stationAlong.sorted(), "\(pattern.id) stations run forward along the track")
        }
    }

    func testTimelineDwellsRunsCoastsThenHolds() throws {
        let metro = try network(), pattern = try bannan(metro)
        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = MetroTrainPlan(stationIndex: 5, arrivedAt: seen, departure: seen + 25, lastSeen: seen)

        let dwelling = try XCTUnwrap(MetroTrainTimeline.state(plan, pattern: pattern, at: seen + 10))
        XCTAssertTrue(dwelling.atPlatform); XCTAssertEqual(dwelling.previousIndex, 5); XCTAssertEqual(dwelling.progress, 0)
        XCTAssertEqual(MetroTrainTimeline.secondsUntil(5, state: dwelling, pattern: pattern), 0, "Standing at the platform")

        let run = MetroTrainTimeline.run(pattern, 5)
        let moving = try XCTUnwrap(MetroTrainTimeline.state(plan, pattern: pattern, at: seen + 25 + run / 2))
        XCTAssertFalse(moving.atPlatform); XCTAssertEqual(moving.nextIndex, 6)
        XCTAssertEqual(moving.progress, 0.5, accuracy: 0.01)
        XCTAssertEqual(moving.secondsToNext, run / 2, accuracy: 0.5)
        XCTAssertNil(MetroTrainTimeline.secondsUntil(5, state: moving, pattern: pattern), "Already left")

        // One unseen station is passed on running times, the next one is where it waits.
        let coastStart = seen + 25 + run + MetroTrainTimeline.dwell(pattern, 6) + 1
        let coasting = try XCTUnwrap(MetroTrainTimeline.state(plan, pattern: pattern, at: coastStart))
        XCTAssertEqual(coasting.nextIndex, 7); XCTAssertFalse(coasting.holding)
        let reach = arrival(pattern, from: 5, departure: seen + 25, to: 7)
        let held = try XCTUnwrap(MetroTrainTimeline.state(plan, pattern: pattern, at: reach + 30))
        XCTAssertTrue(held.holding); XCTAssertEqual(held.previousIndex, 7)
        XCTAssertNil(MetroTrainTimeline.secondsUntil(8, state: held, pattern: pattern),
                     "A held estimate has no observed departure and cannot promise an arrival")
        XCTAssertNil(MetroTrainTimeline.state(plan, pattern: pattern, at: reach + MetroTrainTimeline.holdSeconds + 5),
                     "A train that is never seen again disappears instead of standing still forever")
    }

    func testConsecutiveSightingsKeepOneTrainAndSeparateTheFollower() throws {
        let metro = try network(), pattern = try bannan(metro)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var tracker = MetroTrainTracker()
        // Train A seen at 4, listed again while dwelling, then at 5 and (skipping 6) at 7.
        tracker.ingest([event(pattern, 4, start)], network: metro, at: start)
        tracker.ingest([event(pattern, 4, start + 12)], network: metro, at: start + 15)
        let at5 = arrival(pattern, from: 4, departure: start + 25, to: 5) + 8
        tracker.ingest([event(pattern, 5, at5)], network: metro, at: at5 + 3)
        // Train B, four minutes behind, enters 4 while A is on its way.
        let at7 = arrival(pattern, from: 5, departure: at5 + 25, to: 7) - 10
        tracker.ingest([event(pattern, 7, at7), event(pattern, 4, start + 240)], network: metro, at: max(at7, start + 240) + 2)

        XCTAssertEqual(tracker.tracks.count, 2)
        let a = try XCTUnwrap(tracker.tracks.first { $0.plan.stationIndex == 7 })
        XCTAssertEqual(a.sightings, 4)
        XCTAssertEqual(a.id, tracker.tracks.min { $0.id.count == $1.id.count ? $0.id < $1.id : $0.id.count < $1.id.count }?.id,
                       "The first train keeps its identity across stations")
        let b = try XCTUnwrap(tracker.tracks.first { $0.plan.stationIndex == 4 })
        XCTAssertNotEqual(a.id, b.id)

        // A sighting far too early for the train behind starts a new train rather than teleporting it.
        let reports = tracker.reports(network: metro, at: start + 250)
        XCTAssertEqual(Set(reports.map(\.id)), Set([a.id, b.id]))
        XCTAssertTrue(reports.allSatisfy(\.isEstimated))
    }

    func testOppositeDirectionAndOtherDestinationsNeverMerge() throws {
        let metro = try network(), pattern = try bannan(metro)
        let back = try XCTUnwrap(metro.patterns.first { $0.id == "metro:TRTC:BL-1" && $0.direction == "1" })
        let shortTurn = try XCTUnwrap(metro.patterns.first { $0.id == "metro:TRTC:BL-2" && $0.direction == "0" })
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var tracker = MetroTrainTracker()
        tracker.ingest([event(pattern, 8, start)], network: metro, at: start)
        let next = arrival(pattern, from: 8, departure: start + 25, to: 9)
        let station = pattern.stationIDs[9]
        let reverse = try XCTUnwrap(back.stationIDs.firstIndex(of: station))
        let shortIndex = try XCTUnwrap(shortTurn.stationIDs.firstIndex(of: station))
        tracker.ingest([event(back, reverse, next), event(shortTurn, shortIndex, next + 1)], network: metro, at: next + 2)
        XCTAssertEqual(tracker.tracks.count, 3)
    }

    func testLostTrainIsPickedUpUnderTheSameIdentity() throws {
        let metro = try network(), pattern = try bannan(metro)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var tracker = MetroTrainTracker()
        tracker.ingest([event(pattern, 3, start)], network: metro, at: start)
        let id = try XCTUnwrap(tracker.tracks.first?.id)
        // Nothing for long enough that it is dropped from the map...
        let reach = arrival(pattern, from: 3, departure: start + 25, to: 5)
        tracker.prune(network: metro, at: reach + MetroTrainTimeline.holdSeconds + 10)
        XCTAssertTrue(tracker.tracks.isEmpty)
        // ...then seen again further down the line, on time.
        let later = arrival(pattern, from: 3, departure: start + 25, to: 8)
        tracker.ingest([event(pattern, 8, later + 20)], network: metro, at: later + 22)
        XCTAssertEqual(tracker.tracks.map(\.id), [id])
    }

    func testEstimatedReportsMoveSmoothlyAlongTheTrack() throws {
        let metro = try network(), pattern = try bannan(metro)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var tracker = MetroTrainTracker()
        tracker.ingest([event(pattern, 6, start)], network: metro, at: start)
        let report = try XCTUnwrap(tracker.reports(network: metro, at: start).first)
        let geometry = try XCTUnwrap(MetroPatternGeometry(pattern: pattern))
        let train = try XCTUnwrap(PreparedMetroTrain(report: report, network: metro, geometry: geometry))
        var previous: Coordinate?
        var largest = 0.0
        for second in stride(from: 0.0, through: 200, by: 1) {
            let pose = try XCTUnwrap(train.renderPose(at: start + second))
            if let previous { largest = max(largest, previous.distance(to: pose.coordinate)) }
            previous = pose.coordinate
        }
        XCTAssertLessThan(largest, 40, "No frame-to-frame jump larger than a fast train covers in a second")
        let station = try XCTUnwrap(metro.station(pattern.stationIDs[6]))
        XCTAssertLessThan(try XCTUnwrap(train.renderPose(at: start + 5)).coordinate.distance(to: station.coordinate), 150,
                          "A train just seen entering a station is drawn at that station")
    }

    func testOfficialReportsKeepTheirOwnState() throws {
        let metro = try network(), pattern = try bannan(metro)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = MetroTrainReport(id: "T1", operatorID: "TRTC", patternID: pattern.id, direction: pattern.direction,
            nextStationID: pattern.stationIDs[4], destinationStationID: pattern.stationIDs.last!, remainingSeconds: 40,
            observedAt: now, atPlatform: false)
        let state = try XCTUnwrap(report.state(network: metro, at: now + 10))
        XCTAssertEqual(state.nextIndex, 4); XCTAssertEqual(state.secondsToNext, 30, accuracy: 0.01)
        XCTAssertNil(report.state(network: metro, at: now + 90), "An official report is valid for a minute")
        XCTAssertFalse(report.isEstimated)
    }
}

extension MetroTrainTrackerTests {
    func testRelistingAtThePlatformAndLateArrivalsNeverMoveATrainBackwards() throws {
        let metro = try network(), pattern = try bannan(metro)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var tracker = MetroTrainTracker()
        var shown: [Double] = []
        func record(_ t: Date) {
            guard let track = tracker.tracks.first, let state = MetroTrainTimeline.state(track.plan, pattern: pattern, at: t) else { return }
            shown.append(MetroTrainPlan.position(state))
        }
        // Listed at station 4 for 40 s (the feed relists a train while it stands at the platform)...
        for offset in stride(from: 0.0, through: 40, by: 14) {
            tracker.ingest([event(pattern, 4, start + offset)], network: metro, at: start + offset + 1)
            record(start + offset + 1)
        }
        // ...then seen entering station 5 a little later than the running time predicts.
        let late = start + 40 + MetroTrainTimeline.departAfterLastListing + MetroTrainTimeline.run(pattern, 4) + 15
        for second in stride(from: start + 42, to: late, by: 2) { record(second) }
        tracker.ingest([event(pattern, 5, late)], network: metro, at: late + 1)
        for second in stride(from: late + 1, to: late + 120, by: 2) { record(second) }
        XCTAssertEqual(tracker.tracks.count, 1)
        for (a, b) in zip(shown, shown.dropFirst()) { XCTAssertGreaterThanOrEqual(b, a - 1e-9, "The drawn train only moves forward") }
    }
}
