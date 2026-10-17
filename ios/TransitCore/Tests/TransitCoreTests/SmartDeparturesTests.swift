import XCTest
@testable import TransitCore

final class SmartDeparturesTests: XCTestCase {
    func testOfficialFirstThenCatchablePhysicalBusBeforeHeadway() throws {
        let buses = [BoardingDeparture(seconds:120,spread:30),.init(seconds:480,spread:40),.init(seconds:900,spread:60)]
        let reachable = BoardingTime.wait(official:420,readyAt:300,buffer:60,departures:buses)
        XCTAssertEqual(reachable.evidence,.official); XCTAssertEqual(reachable.departureSeconds,420)
        let later = BoardingTime.wait(official:60,readyAt:300,buffer:60,departures:buses)
        XCTAssertEqual(later.evidence,.gps); XCTAssertEqual(later.departureSeconds,480)
        XCTAssertEqual(later.seconds,180); XCTAssertTrue(later.missedNext)
        // The bus may run early; don't recommend a marginal sprint.
        let tight = BoardingTime.wait(official:nil,readyAt:430,buffer:30,departures:buses)
        XCTAssertEqual(tight.departureSeconds,900)
        for status in [-1,-2,-3,-4] {
            XCTAssertNotEqual(BoardingTime.wait(official:status,readyAt:0,buffer:0,departures:buses).evidence,.gps)
        }
    }
    func testGPSDepartureIsAnchoredOnceAcrossWholeTrip() {
        let assessment = TripRanking.assess(riding:[600,300],walking:[300,60,120],arrivals:[nil,1_200],
            boardingBuffers:[60,0],departures:[[.init(seconds:480,spread:40)],[]])
        XCTAssertEqual(assessment.waits[0].evidence,.gps)
        XCTAssertEqual(assessment.waits[1].evidence,.official)
        XCTAssertEqual(assessment.waitingSeconds,240,accuracy:0.001)
        XCTAssertEqual(assessment.elapsedSeconds,1_620,accuracy:0.001)
        XCTAssertEqual(assessment.unknownWaits,0)
        XCTAssertEqual(assessment.lowerSeconds,assessment.upperSeconds,accuracy:0.001)
    }
    func testInvalidAndPassedGPSDeparturesCannotBecomeFreeWaits() {
        let invalid = [BoardingDeparture(seconds:.nan,spread:30),.init(seconds:100,spread:.infinity),
            .init(seconds:-100,spread:0),.init(seconds:100,spread:-20)]
        let result = BoardingTime.wait(official:nil,readyAt:300,buffer:60,departures:invalid)
        XCTAssertEqual(result.evidence,.unknown); XCTAssertNil(result.departureSeconds)
        XCTAssertEqual(BoardingTime.wait(official:nil,readyAt:0,buffer:0,
            departures:[.init(seconds:0,spread:30)]).evidence,.gps)
    }
    func testReasonsExplainTheActualTradeoff() {
        let a = JourneyChoice(id:"a",group:"",elapsed:1_800,walking:300,waiting:120,transfers:0,rentals:0,unknownWaits:0)
        let b = JourneyChoice(id:"b",group:"",elapsed:1_650,walking:600,waiting:120,transfers:1,rentals:0,unknownWaits:0)
        XCTAssertEqual(JourneyChoiceRanking.reason(for:a,comparedTo:b),"多花 3 分，少轉乘 1 次")
        XCTAssertEqual(JourneyChoiceRanking.reason(for:b,comparedTo:a),"快約 3 分")
    }
    func testFrameSamplingRunsAnHourAcrossRefreshRatesAndResumes() throws {
        var sampler = FramePacingWindow(interval:60), reports: [FramePacingWindow.Report] = []
        var time = 0.0
        for minute in 0..<60 {
            let rate = minute < 30 ? 120.0 : 60.0
            if minute == 30 { sampler.reset(); time += 600 } // Real background pause is not a dropped frame.
            for frame in 0..<Int(rate*60) {
                time += frame == 50 ? 3/rate : 1/rate
                if let report = sampler.observe(timestamp:time,targetInterval:1/rate) { reports.append(report) }
            }
        }
        XCTAssertGreaterThanOrEqual(reports.count,58)
        XCTAssertTrue(reports.allSatisfy { $0.delayedFrames > 0 && $0.longestGapMilliseconds < 100 })
        XCTAssertGreaterThan(try XCTUnwrap(reports.first).framesPerSecond,115)
        XCTAssertLessThan(try XCTUnwrap(reports.last).framesPerSecond,61)
    }
}
