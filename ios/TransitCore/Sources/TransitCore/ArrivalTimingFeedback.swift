import Foundation

/// A small, session-local feedback loop over public fleet reports. It compares
/// an uncorrected prediction with a later interpolated stop crossing. No phone
/// coordinates, extra requests, or uploaded analytics are involved.
struct ArrivalTimingFeedback: Sendable {
    private struct Pending: Sendable {
        let key: String
        let stopID: String
        let seconds: Double
        let date: Date
    }
    private struct Sample: Sendable { let vehicle: String; let ratio: Double; let date: Date }
    private var pending: [String: Pending] = [:]
    private var samples: [String: [Sample]] = [:]
    func needsPrediction(vehicle: String) -> Bool { pending[vehicle] == nil }
    mutating func begin(vehicle: String, key: String, stopID: String, seconds: Double, at date: Date) {
        guard pending[vehicle] == nil, seconds.isFinite, (30...600).contains(seconds) else { return }
        pending[vehicle] = Pending(key:key,stopID:stopID,seconds:seconds,date:date)
    }
    mutating func crossed(vehicle: String, key: String, stopID: String, at date: Date) {
        guard let value = pending[vehicle], value.stopID == stopID else { return }
        pending[vehicle] = nil
        let actual = date.timeIntervalSince(value.date)
        guard value.key == key, (15...900).contains(actual), (0.4...2.5).contains(actual/value.seconds) else { return }
        var values = samples[key,default:[]].filter { date.timeIntervalSince($0.date) <= 1_200 }
        // Multiple packets or repeated laps by one bus cannot create a fleet consensus.
        values.removeAll { $0.vehicle == vehicle }
        values.append(Sample(vehicle:vehicle,ratio:actual/value.seconds,date:date))
        samples[key] = Array(values.suffix(12))
    }
    mutating func discard(vehicle: String) { pending[vehicle] = nil }
    mutating func prune(at date: Date) {
        pending = pending.filter { (-5...900).contains(date.timeIntervalSince($0.value.date)) }
        samples = samples.compactMapValues {
            let fresh = $0.filter { (-5...1_200).contains(date.timeIntervalSince($0.date)) }
            return fresh.isEmpty ? nil : fresh
        }
        if samples.count > 1_024 {
            let oldest = samples.sorted { ($0.value.last?.date ?? .distantPast) < ($1.value.last?.date ?? .distantPast) }
            for entry in oldest.prefix(samples.count-1_024) { samples[entry.key] = nil }
        }
    }
    func factor(for key: String, at date: Date) -> Double {
        let values = samples[key,default:[]].filter { (-5...1_200).contains(date.timeIntervalSince($0.date)) }.map(\.ratio).sorted()
        guard values.count >= 3 else { return 1 }
        let median = values.count % 2 == 0 ? (values[values.count/2-1]+values[values.count/2])/2 : values[values.count/2]
        // Never let a small online sample overwrite the official profile or
        // swing a GPS fallback by more than 20 percent.
        return 1 + min(0.2,max(-0.2,(median-1)*min(1,Double(values.count)/5)))
    }
}
