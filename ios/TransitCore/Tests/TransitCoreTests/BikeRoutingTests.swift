import XCTest
@testable import TransitCore

final class BikeRoutingTests: XCTestCase {
    private let origin = Coordinate(latitude: 25.0300, longitude: 121.5000)
    private let destination = Coordinate(latitude: 25.0300, longitude: 121.5205)

    private func station(_ id: String, _ latitude: Double, _ longitude: Double) -> BikeStation {
        BikeStation(id: id, name: "站" + id, district: "大安區",
                    coordinate: Coordinate(latitude: latitude, longitude: longitude), capacity: 30)
    }
    /// Near the origin, a second one slightly farther, one by the destination, and one behind it.
    private func network() -> BikeNetwork {
        BikeNetwork(schema: 1, generatedAt: "", source: "test", stations: [
            station("near", 25.0303, 121.5003),
            station("far", 25.0310, 121.5010),
            station("arrival", 25.0300, 121.5200),
            station("behind", 25.0300, 121.4900),
        ])
    }
    private func availability(_ counts: [String: (rent: Int, back: Int)], age: TimeInterval = 60,
                              active: Set<String>? = nil, at date: Date) -> BikeAvailability {
        var docks: [String: BikeDock] = [:]
        for (id, count) in counts {
            docks[id] = BikeDock(stationID: id, rentable: count.rent, returnable: count.back, capacity: 30,
                                 active: active?.contains(id) ?? true, observedAt: date.addingTimeInterval(-age))
        }
        return BikeAvailability(docks: docks, receivedAt: date)
    }
    private var stocked: [String: (rent: Int, back: Int)] {
        ["near": (8, 10), "far": (9, 10), "arrival": (4, 9), "behind": (9, 9)]
    }

    func testRidingUsesTheNearestStationThatHasBikesAndSomewhereToReturnThem() throws {
        let now = Date()
        let connection = try XCTUnwrap(BikeRouting.connection(from: origin, to: destination, network: network(),
                                                              availability: availability(stocked, at: now), at: now))
        XCTAssertEqual(connection.pickup.id, "near")
        XCTAssertEqual(connection.dropoff.id, "arrival")
        XCTAssertEqual(connection.bikes, 8)
        XCTAssertEqual(connection.docks, 9)
        XCTAssertGreaterThan(connection.rideMeters, 1_900)
        // Unlocking and docking are part of the trip, not free.
        XCTAssertEqual(connection.handlingSeconds, LiveSettings.Planning().bikeHandlingSeconds)
        XCTAssertGreaterThan(connection.totalSeconds, connection.rideSeconds)
        // Two kilometres on a bike beats the same two kilometres on foot by a wide margin.
        XCTAssertTrue(BikeRouting.worthRiding(connection, insteadOfWalking: origin.distance(to: destination)))
    }

    func testAStationWithoutBikesOrWithoutDocksIsNeverProposed() {
        let now = Date(), network = network()
        func connection(_ counts: [String: (rent: Int, back: Int)], age: TimeInterval = 60, active: Set<String>? = nil) -> BikeConnection? {
            BikeRouting.connection(from: origin, to: destination, network: network,
                                   availability: availability(counts, age: age, active: active, at: now), at: now)
        }
        XCTAssertNil(connection(["arrival": (4, 9)]))                                   // nothing to rent
        XCTAssertNil(connection(["near": (8, 10)]))                                     // nowhere to return it
        XCTAssertNil(connection(["near": (1, 10), "arrival": (4, 9)]))                  // the last bike is not a plan
        XCTAssertNil(connection(["near": (8, 10), "arrival": (4, 1)]))                  // the last dock is not either
        XCTAssertNil(connection(stocked, active: ["arrival"]))                          // pickup suspended
        XCTAssertNil(connection(stocked, active: ["near"]))                             // return station suspended
        // Counts from half an hour ago say nothing about what is standing there now.
        XCTAssertNil(connection(stocked, age: 1_800))
        // Without any counts at all the app does not guess.
        XCTAssertNil(BikeRouting.connection(from: origin, to: destination, network: network, availability: nil, at: now))
        // Neither does it ride when the whole trip is a short walk.
        XCTAssertNil(BikeRouting.connection(from: origin, to: Coordinate(latitude: 25.0300, longitude: 121.5030),
                                            network: network, availability: availability(stocked, at: now), at: now))
    }

    func testCyclingIsRefusedWhenItOnlyAddsDetoursOrIsTurnedOff() {
        let now = Date(), network = network()
        // Only a station behind the rider has bikes: fetching one there and riding back past
        // the origin is a detour, not a shortcut, even with a generous walk to the station.
        var reachable = LiveSettings.Planning(); reachable.bikeAccessMeters = 1_200
        XCTAssertNil(BikeRouting.connection(from: origin, to: destination, network: network,
                                            availability: availability(["behind": (9, 9), "arrival": (4, 9)], at: now),
                                            preferences: reachable, at: now))
        var off = LiveSettings.Planning(); off.bikeRouting = false
        XCTAssertNil(BikeRouting.connection(from: origin, to: destination, network: network,
                                            availability: availability(stocked, at: now), preferences: off, at: now))
        var shortRides = LiveSettings.Planning(); shortRides.bikeMaximumRideMeters = 1_000
        XCTAssertNil(BikeRouting.connection(from: origin, to: destination, network: network,
                                            availability: availability(stocked, at: now), preferences: shortRides, at: now))
        // Saving a minute is not worth unlocking a bike for.
        let connection = BikeRouting.connection(from: origin, to: destination, network: network,
                                                availability: availability(stocked, at: now), at: now)
        XCTAssertFalse(BikeRouting.worthRiding(connection, insteadOfWalking: 400))
        XCTAssertFalse(BikeRouting.worthRiding(nil, insteadOfWalking: 5_000))
    }

    func testAStationThatRanOutIsReportedWithSomewhereElseToGo() throws {
        let now = Date(), network = network()
        let near = try XCTUnwrap(network.station("near"))
        let empty = availability(["near": (0, 10), "far": (9, 10), "arrival": (4, 9)], at: now)
        XCTAssertFalse(BikeRouting.stillUsable(near, availability: empty, renting: true))
        // One bike left is thin, but it is not yet a reason to send the rider elsewhere.
        let last = availability(["near": (1, 10)], at: now)
        XCTAssertTrue(BikeRouting.stillUsable(near, availability: last, renting: true))
        let suspended = availability(["near": (9, 9)], active: [], at: now)
        XCTAssertFalse(BikeRouting.stillUsable(near, availability: suspended, renting: true))
        // Without a current count the plan stands rather than being thrown away.
        XCTAssertTrue(BikeRouting.stillUsable(near, availability: availability([:], at: now), renting: true))
        XCTAssertEqual(BikeRouting.replacement(for: near, network: network, availability: empty, renting: true)?.id, "far")
        // A station with nothing to offer either is not a replacement.
        let bothEmpty = availability(["near": (0, 10), "far": (0, 10)], at: now)
        XCTAssertNil(BikeRouting.replacement(for: near, network: network, availability: bothEmpty, renting: true))
    }
}
