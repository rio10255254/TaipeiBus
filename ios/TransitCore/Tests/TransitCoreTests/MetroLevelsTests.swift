import XCTest
@testable import TransitCore

final class MetroLevelsTests: XCTestCase {
    private func network() throws -> MetroNetwork {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TaipeiBus")
        let metro = try MetroNetwork(data: Data(contentsOf: root.appendingPathComponent("MetroNetwork.json")))
        let levels = try MetroLevels(data: Data(contentsOf: root.appendingPathComponent("MetroLevels.json")))
        return metro.withLevels(levels)
    }
    private func height(_ metro: MetroNetwork, pattern id: String, station name: String) throws -> Double {
        let pattern = try XCTUnwrap(metro.patterns.first { $0.id == id && $0.direction == "0" })
        let index = try XCTUnwrap(pattern.stationIDs.firstIndex { metro.station($0)?.name == name })
        let geometry = try XCTUnwrap(MetroPatternGeometry(pattern: pattern, profile: metro.heightProfile(pattern)))
        return geometry.height(along: geometry.stationAlong[index])
    }

    func testEveryPatternHasAProfileForThisNetworkSnapshot() throws {
        let metro = try network()
        for pattern in metro.patterns { XCTAssertNotNil(metro.heightProfile(pattern), MetroLevels.key(pattern)) }
    }

    func testKnownStructuresAndInterchangeLayering() throws {
        let metro = try network()
        // Wenhu runs on a viaduct over the Bannan line at Zhongxiao Fuxing, and in a tunnel at Songshan Airport.
        XCTAssertGreaterThan(try height(metro, pattern: "metro:TRTC:BR-1", station: "忠孝復興"), 8)
        XCTAssertLessThan(try height(metro, pattern: "metro:TRTC:BL-1", station: "忠孝復興"), -10)
        XCTAssertLessThan(try height(metro, pattern: "metro:TRTC:BR-1", station: "松山機場"), -10)
        // Tamsui is on a viaduct north of Yuanshan; Sanying is a viaduct throughout.
        XCTAssertGreaterThan(try height(metro, pattern: "metro:TRTC:R-1", station: "圓山"), 8)
        XCTAssertGreaterThan(try height(metro, pattern: "metro:NTMC:LB", station: "頂埔"), 8)
        // Interchanges stack different lines at different depths instead of on one plane.
        XCTAssertNotEqual(try height(metro, pattern: "metro:TRTC:BL-1", station: "台北車站"),
                          try height(metro, pattern: "metro:TRTC:R-1", station: "台北車站"))
        XCTAssertNotEqual(try height(metro, pattern: "metro:TRTC:BL-1", station: "忠孝新生"),
                          try height(metro, pattern: "metro:TRTC:O-1", station: "忠孝新生"))
    }

    func testTrainsClimbAndDescendGraduallyAtPortals() throws {
        let metro = try network()
        for pattern in metro.patterns {
            let profile = try XCTUnwrap(metro.heightProfile(pattern))
            let length = RouteLine(coordinates: pattern.coordinates).length
            var previous = profile.height(at: 0)
            for distance in stride(from: 5.0, through: length, by: 5) {
                let value = profile.height(at: distance)
                XCTAssertLessThan(abs(value - previous), 2.6, "\(MetroLevels.key(pattern)) steep at \(Int(distance)) m")
                previous = value
            }
        }
    }

    func testLevelsForAnotherSnapshotAreIgnored() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TaipeiBus")
        let metro = try MetroNetwork(data: Data(contentsOf: root.appendingPathComponent("MetroNetwork.json")))
        let json = #"{"schema":1,"source":"t","license":"t","networkGeneratedAt":"older","profiles":{"metro:TRTC:BL-1|0":[[0,-20]]}}"#
        let attached = metro.withLevels(try MetroLevels(data: Data(json.utf8)))
        XCTAssertTrue(attached.heightProfiles.isEmpty, "Heights matched to other geometry must not be applied")
        XCTAssertThrowsError(try MetroLevels(data: Data(#"{"schema":1,"source":"t","license":"t","networkGeneratedAt":"x","profiles":{"a":[[5,0],[1,0]]}}"#.utf8)))
    }

    func testTrainPoseCarriesTrackHeight() throws {
        let metro = try network()
        let pattern = try XCTUnwrap(metro.patterns.first { $0.id == "metro:TRTC:BR-1" && $0.direction == "0" })
        let index = try XCTUnwrap(pattern.stationIDs.firstIndex { metro.station($0)?.name == "大安" })
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = MetroTrainReport(id: "est", operatorID: "TRTC", patternID: pattern.id, direction: pattern.direction,
            nextStationID: pattern.stationIDs[index + 1], destinationStationID: pattern.stationIDs.last!, remainingSeconds: 60,
            observedAt: now, atPlatform: false,
            plan: MetroTrainPlan(stationIndex: index, arrivedAt: now, departure: now + 20, lastSeen: now))
        let train = try XCTUnwrap(PreparedMetroTrain(report: report, network: metro))
        XCTAssertGreaterThan(try XCTUnwrap(train.renderPose(at: now + 5)).elevation, 8, "Daan on the Wenhu line is elevated")
    }
}

extension MetroLevelsTests {
    func testWenhuSplitsIntoViaductAndTunnelPiecesThatCoverTheLine() throws {
        let metro = try network()
        let pattern = try XCTUnwrap(metro.patterns.first { $0.id == "metro:TRTC:BR-1" && $0.direction == "0" })
        let line = RouteLine(coordinates: pattern.coordinates)
        let pieces = try XCTUnwrap(metro.heightProfile(pattern)).pieces(of: line)
        XCTAssertTrue(pieces.contains { $0.structure == .elevated })
        XCTAssertTrue(pieces.contains { $0.structure == .underground })
        let total = pieces.map { RouteLine(coordinates: $0.coordinates).length }.reduce(0, +)
        XCTAssertEqual(total, line.length, accuracy: line.length * 0.01)
        for (a, b) in zip(pieces, pieces.dropFirst()) {
            XCTAssertLessThan(a.coordinates.last!.distance(to: b.coordinates.first!), 1, "Pieces join without gaps")
        }
    }
}

extension MetroLevelsTests {
    func testViaductsStandOnPiersAndAreNotDrawnTwice() throws {
        let metro = try network()
        let origin = Coordinate(latitude: 25.04, longitude: 121.55)
        let metersPerWorld = 40_075_016.68557849 * cos(origin.latitude * .pi / 180)
        let mesh = MetroStructureMesh.viaducts(network: metro, origin: origin, metersPerWorld: metersPerWorld) { _ in (1, 0, 0) }
        XCTAssertEqual(mesh.count % 3, 0)
        XCTAssertGreaterThan(mesh.count, 3_000)
        XCTAssertLessThan(mesh.count * 48, 8_000_000, "Static mesh stays a few megabytes")
        XCTAssertTrue(mesh.allSatisfy { $0.z >= -0.01 && $0.z < 40 }, "Viaducts are above ground")
        XCTAssertTrue(mesh.contains { $0.z == 0 }, "Piers reach the street")
        // Daan on the Wenhu line is elevated, Taipei Main is not (station points sit between platforms).
        func near(_ name: String, _ code: String) throws -> Bool {
            let station = try XCTUnwrap(metro.stations.first { $0.name == name && $0.code.hasPrefix(code) })
            let m = station.coordinate.mercator, o = origin.mercator
            let east = Float((m.x - o.x) * metersPerWorld), north = Float(-(m.y - o.y) * metersPerWorld)
            return mesh.contains { hypot($0.x - east, $0.y - north) < 150 && $0.z > 5 }
        }
        XCTAssertTrue(try near("大安", "BR"))
        XCTAssertFalse(try near("台北車站", "BL"))
    }
}
