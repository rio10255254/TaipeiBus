import XCTest
@testable import TransitCore

final class OfficialTravelTimeTests: XCTestCase {
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func catalog(route: String = "family", subroute: String = "arbitrary-subroute", updated: String = "2026-10-05T05:26:38+08:00", seconds: [Int] = [30]) throws -> OfficialTravelTimes {
        let object: [String: Any] = ["schema": 1, "routes": [["route": route, "subroute": subroute, "direction": "1", "updated": updated, "edges": [["from", "to"]], "periods": [["weekday": 2, "startHour": 10, "endHour": 11, "seconds": seconds]]]]]
        return try OfficialTravelTimes(data: JSONSerialization.data(withJSONObject: object))
    }
    func testAllRouteIdentifiersUseTheirOwnDirectionDayHourAndStops() throws {
        let at = date("2026-10-06T10:15:00+08:00")
        let value = try catalog()
        XCTAssertEqual(value.seconds(route: "family", subroute: "arbitrary-subroute", direction: "1", from: "from", to: "to", travellingAt: at, observedAt: at), 30)
        for (family, subroute, direction, from, to) in [("another-family", "arbitrary-subroute", "1", "from", "to"), ("family", "another-subroute", "1", "from", "to"), ("family", "arbitrary-subroute", "0", "from", "to"), ("family", "arbitrary-subroute", "1", "to", "from")] {
            XCTAssertNil(value.seconds(route: family, subroute: subroute, direction: direction, from: from, to: to, travellingAt: at, observedAt: at))
        }
        XCTAssertNil(value.seconds(route: "family", subroute: "arbitrary-subroute", direction: "1", from: "from", to: "to", travellingAt: date("2026-10-06T11:15:00+08:00"), observedAt: at))
        XCTAssertNil(value.seconds(route: "family", subroute: "arbitrary-subroute", direction: "1", from: "from", to: "to", travellingAt: date("2026-10-07T10:15:00+08:00"), observedAt: at))
    }
    func testExpiredAndUnavailableSourceValuesAreNeverOfficialTimes() throws {
        let at = date("2026-10-06T10:15:00+08:00")
        for value in [try catalog(updated: "2026-08-01T05:26:38+08:00"), try catalog(seconds: [-1]), try catalog(seconds: [0]), try catalog(seconds: [4000])] {
            XCTAssertNil(value.seconds(route: "family", subroute: "arbitrary-subroute", direction: "1", from: "from", to: "to", travellingAt: at, observedAt: at))
        }
    }
    func testRecordedOfficial630EighteenSegmentsTotal1635Seconds() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Official630TimingEvidence", withExtension: "json"))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let values = try XCTUnwrap(raw["stop_to_stop_seconds"] as? [Int])
        let edges = (23640..<23658).map { [String($0), String($0 + 1)] }
        let object: [String: Any] = ["schema": 1, "routes": [["route": "10861", "subroute": "160878", "direction": "1", "updated": raw["source_updated_at"]!, "edges": edges, "periods": [["weekday": 2, "startHour": 10, "endHour": 11, "seconds": values]]]]]
        let profile = try OfficialTravelTimes(data: JSONSerialization.data(withJSONObject: object))
        let at = date("2026-10-06T10:15:00+08:00")
        let total = try edges.reduce(0.0) { sum, edge in
            sum + (try XCTUnwrap(profile.seconds(route: "10861", subroute: "160878", direction: "1", from: edge[0], to: edge[1], travellingAt: at, observedAt: at)))
        }
        XCTAssertEqual(total, 1635); XCTAssertEqual(total / 60, 27.25)
    }

    func testDownloadedCatalogMatchesEveryRecordedNeihuToDunhuaSegment() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "OfficialTravelProfilesRecorded", withExtension: "json"))
        let value = try OfficialTravelTimes(data: Data(contentsOf: url))
        XCTAssertEqual(value.patternCount, 4)
        let at = date("2026-10-06T10:15:00+08:00")
        let total = try (23640..<23658).reduce(0.0) { sum, stop in
            sum + (try XCTUnwrap(value.seconds(route: "10861", subroute: "160878", direction: "1",
                from: String(stop), to: String(stop + 1), travellingAt: at, observedAt: at)))
        }
        XCTAssertEqual(total, 1635)
    }

    func testSharedEstimatorUsesOfficialTimeWithoutAddingDwellAgain() throws {
        let pair = RidingTrafficTests().source()
        var metadata = pair.0
        let ride = pair.1
        let periods: [[String: Any]] = [["weekday": 2, "startHour": 10, "endHour": 11, "seconds": [100, 100, 100, 100]],
                                       ["weekday": 2, "startHour": 11, "endHour": 12, "seconds": [300, 300, 300, 300]]]
        let object: [String: Any] = ["schema": 1, "routes": [["route": "family", "subroute": "observed", "direction": "0",
            "updated": "2026-10-05T05:26:38.100+08:00", "edges": (0..<4).map { ["s\($0)", "s\($0 + 1)"] }, "periods": periods]]]
        metadata.officialTravelTimes = try OfficialTravelTimes(data: JSONSerialization.data(withJSONObject: object))
        let now = date("2026-10-06T10:50:00+08:00"), forecast = VehicleArrivalForecast()
        let estimate = forecast.ridingEstimate(ride, metadata: metadata, at: now)
        XCTAssertEqual(estimate.seconds, 400); XCTAssertEqual(estimate.evidence, .officialProfile)
        // The walk and official departure cross into 11:00 before boarding.
        let trip = TransitTrip(rides: [ride], accessDistance: 100, egressDistance: 0, transferDistance: 0,
                               score: 0, rideSeconds: [400])
        let values = forecast.plannedRidingEstimates(trip, metadata: metadata,
            estimates: EstimateFeed(seconds: ["family:s0": 900], updatedAt: now), walkingDurations: [180, 0], at: now)
        XCTAssertEqual(values.first?.seconds, 1200)
        XCTAssertEqual(values.first?.evidence, .officialProfile)
        // GPS freshness is evaluated now, not against the later boarding clock.
        XCTAssertEqual(forecast.ridingEstimate(ride, metadata: metadata, at: now,
            travellingAt: date("2026-10-06T11:15:00+08:00")).seconds, 1200)
    }
}
