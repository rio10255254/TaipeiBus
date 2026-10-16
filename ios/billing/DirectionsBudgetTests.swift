import XCTest
import MapKit
@testable import TaipeiBus

@MainActor final class DirectionsBudgetTests: XCTestCase {
    func testAlternativesReserveCapacityForANewSearchAndNavigation() async throws {
        let gate = DirectionsRequestGate(window:0.25,limits:[4,3,1],concurrency:1,spacing:0)
        let first = try await gate.acquire(.alternatives); gate.release(first)
        do { _ = try await gate.acquire(.alternatives); XCTFail("Optional comparisons must stop before exhausting new-search capacity") }
        catch is DirectionsRequestGate.Deferred {} catch { XCTFail("Unexpected \(error)") }
        let requested = try await gate.acquire(.firstChoice)
        gate.release(requested)
        let navigation = try await gate.acquire(.navigation)
        gate.release(navigation)
    }
    func testWholeAppWindowAndConcurrencyHoldAcrossSeveralCallers() async throws {
        let gate = DirectionsRequestGate(window:0.15,limits:[4,4,4],concurrency:2,spacing:0.001)
        var starts: [Double] = [], active = 0, maximum = 0
        let tasks = (0..<12).map { _ in Task {
            try await gate.execute(.firstChoice) {
                starts.append(ProcessInfo.processInfo.systemUptime); active += 1; maximum = max(maximum,active)
                defer { active -= 1 }
                try await Task.sleep(for:.milliseconds(8))
            }
        } }
        for task in tasks { try await task.value }
        XCTAssertEqual(starts.count,12); XCTAssertLessThanOrEqual(maximum,2)
        for i in 4..<starts.count { XCTAssertGreaterThanOrEqual(starts[i]-starts[i-4],0.13) }
    }
    func testProviderThrottleWaitsAndRetriesInsteadOfRemovingEveryRoute() async throws {
        let gate = DirectionsRequestGate(window:0.12,limits:[4,4,4],concurrency:2,spacing:0)
        var calls = 0
        let began = ProcessInfo.processInfo.systemUptime
        let result = try await gate.execute(.firstChoice) {
            calls += 1
            if calls == 1 { throw NSError(domain:MKErrorDomain,code:MKError.Code.loadingThrottled.rawValue) }
            return 42
        }
        XCTAssertEqual(result,42); XCTAssertEqual(calls,2)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime-began,0.1)
    }
    func testCancelledOperationReleasesItsSlotForTheNextSearch() async throws {
        let gate = DirectionsRequestGate(window:0.1,limits:[8,8,8],concurrency:1,spacing:0)
        var entered = false
        let old = Task { try await gate.execute(.alternatives) { entered = true; try await Task.sleep(for:.seconds(5)) } }
        for _ in 0..<50 {
            if entered { break }
            try await Task.sleep(for:.milliseconds(2))
        }
        XCTAssertTrue(entered); old.cancel()
        do { try await old.value; XCTFail("The abandoned operation must end") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let next = try await gate.execute(.firstChoice) { 7 }
        XCTAssertEqual(next,7)
    }
    func testServiceInterruptionCanRecoverWithoutBecomingDirectionsNotFound() async throws {
        let gate = DirectionsRequestGate(window:0.05,limits:[4,4,4],concurrency:1,spacing:0)
        var calls = 0
        let result = try await gate.execute(.firstChoice) {
            calls += 1
            if calls == 1 { throw NSError(domain:MKErrorDomain,code:MKError.Code.unknown.rawValue) }
            return "confirmed path"
        }
        XCTAssertEqual(result,"confirmed path"); XCTAssertEqual(calls,2)
        XCTAssertFalse(gate.report(NSError(domain:MKErrorDomain,code:MKError.Code.directionsNotFound.rawValue)),
            "An actual unreachable road is different from a temporarily unavailable service")
    }
}
