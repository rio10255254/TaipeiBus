import Foundation

/// Only report the bus feeds needed by the current screen. A delayed position
/// must not label a fresh official arrival (or an unrelated metro/bike view) stale.
public struct BusDataStatus: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case positions, arrivals, both }
    public enum State: Equatable, Sendable { case updating, delayed }
    public let source: Source
    public let state: State
    public let updatedAt: Date?

    public static func evaluate(_ snapshot: TransitSnapshot, positions: Bool, arrivals: Bool,
                                at now: Date, arrivalFeed: EstimateFeed? = nil) -> BusDataStatus? {
        let estimates = arrivalFeed ?? snapshot.estimates
        func healthy(_ date: Date?, _ error: String?) -> Bool {
            error == nil && date.map { (-60...120).contains(now.timeIntervalSince($0)) } == true
        }
        let positionLate = positions && !healthy(snapshot.sourceUpdatedAt, snapshot.vehicleError)
        let arrivalLate = arrivals && !healthy(estimates.updatedAt, estimates.error)
        guard positionLate || arrivalLate else { return nil }
        let source: Source = positionLate && arrivalLate ? .both : positionLate ? .positions : .arrivals
        let delayed = (positionLate && (snapshot.sourceUpdatedAt != nil || snapshot.vehicleError != nil)) ||
            (arrivalLate && (estimates.updatedAt != nil || estimates.error != nil))
        let dates = [positionLate ? snapshot.sourceUpdatedAt : nil,
                     arrivalLate ? estimates.updatedAt : nil].compactMap { $0 }
        return BusDataStatus(source: source, state: delayed ? .delayed : .updating, updatedAt: dates.min())
    }
}
