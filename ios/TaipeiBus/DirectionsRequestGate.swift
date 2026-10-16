import Foundation
import MapKit
import Combine

/// A bounded on-device troubleshooting history. Deliberately accepts no places,
/// coordinates, route IDs or provider error descriptions. Sharing is user initiated.
@MainActor final class JourneyDiagnostics: ObservableObject {
    static let shared = JourneyDiagnostics()
    private let key = "journeyDiagnostics.v1"
    @Published private(set) var entries: [String]
    init() { entries = Array((UserDefaults.standard.stringArray(forKey:"journeyDiagnostics.v1") ?? []).suffix(80)) }
    func record(_ event: String) {
        let timestamp = ISO8601DateFormatter().string(from:Date())
        entries.append("\(timestamp) \(event)"); entries = Array(entries.suffix(80))
        UserDefaults.standard.set(entries,forKey:key)
    }
    var report: String {
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "?"
        return "TaipeiBus \(version) (\(build))\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nNo coordinates or place names recorded.\n" + entries.joined(separator:"\n")
    }
}

/// One budget for the whole app: initial choices and active guidance retain room
/// even while many optional street/dock combinations are being compared.
@MainActor final class DirectionsRequestGate {
    enum Priority: Int { case navigation, firstChoice, alternatives }
    enum Deferred: Error { case optionalComparison }
    static let shared = DirectionsRequestGate()
    private struct Waiter {
        let id: UUID
        let priority: Priority
        let continuation: CheckedContinuation<Void, Error>
    }
    private let window: Double
    private let limits: [Int]
    private let concurrency: Int
    private let spacing: Double
    private var recent: [Double] = []
    private var active = Set<UUID>()
    private var waiting: [Waiter] = []
    private var wake: Task<Void, Never>?
    private var blockedUntil = 0.0

    init(window: Double = 60, limits: [Int] = [40, 32, 18], concurrency: Int = 2, spacing: Double = 0.35) {
        precondition(window > 0 && limits.count == 3 && limits.allSatisfy { $0 > 0 } && concurrency > 0 && spacing >= 0)
        self.window = window; self.limits = limits; self.concurrency = concurrency; self.spacing = spacing
    }
    func acquire(_ priority: Priority) async throws -> UUID {
        try Task.checkCancellation()
        let now = ProcessInfo.processInfo.systemUptime
        if priority == .alternatives,
           blockedUntil > now || recent.filter({ now-$0 < window }).count >= limits[priority.rawValue] {
            throw Deferred.optionalComparison
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiting.append(Waiter(id:id,priority:priority,continuation:continuation)); drain()
            }
        } onCancel: { Task { @MainActor in self.cancel(id) } }
        do { try Task.checkCancellation() }
        catch { release(id); throw error }
        return id
    }
    func release(_ id: UUID) { active.remove(id); drain() }
    func calculate(_ operation: MKDirections, priority: Priority) async throws -> MKDirections.Response {
        try await execute(priority, cancel: { operation.cancel() }) { try await operation.calculate() }
    }
    func calculateETA(_ operation: MKDirections, priority: Priority) async throws -> MKDirections.ETAResponse {
        try await execute(priority, cancel: { operation.cancel() }) { try await operation.calculateETA() }
    }
    func execute<T>(_ priority: Priority, cancel: @escaping @MainActor () -> Void = {},
                    operation: @escaping @MainActor () async throws -> T) async throws -> T {
        for attempt in 0..<2 {
            let id = try await acquire(priority)
            do {
                let result = try await withTaskCancellationHandler {
                    try await operation()
                } onCancel: { Task { @MainActor in cancel(); self.release(id) } }
                release(id); try Task.checkCancellation(); return result
            } catch {
                let throttled = report(error)
                release(id); try Task.checkCancellation()
                if throttled, attempt == 0 { continue }
                throw error
            }
        }
        throw CancellationError()
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at:index).continuation.resume(throwing:CancellationError()); drain()
    }
    /// Public MapKit errors include both explicit throttling and a temporarily
    /// unavailable service. Neither proves that a walking connection does not exist.
    @discardableResult func report(_ error: Error) -> Bool {
        let value = error as NSError
        let throttle = value.domain == MKErrorDomain && value.code == Int(MKError.Code.loadingThrottled.rawValue)
        let interrupted = value.domain == MKErrorDomain &&
            [Int(MKError.Code.unknown.rawValue),Int(MKError.Code.serverFailure.rawValue)].contains(value.code)
        let network = value.domain == NSURLErrorDomain &&
            [NSURLErrorTimedOut,NSURLErrorNetworkConnectionLost,NSURLErrorCannotConnectToHost].contains(value.code)
        guard throttle || interrupted || network else { return false }
        blockedUntil = max(blockedUntil,ProcessInfo.processInfo.systemUptime + (throttle ? window : min(2,window)))
        drain(); return true
    }
    static func isTemporary(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == MKErrorDomain {
            return [MKError.Code.loadingThrottled, .unknown, .serverFailure].contains { Int($0.rawValue) == value.code }
        }
        return value.domain == NSURLErrorDomain &&
            [NSURLErrorTimedOut,NSURLErrorNetworkConnectionLost,NSURLErrorCannotConnectToHost,
             NSURLErrorNotConnectedToInternet,NSURLErrorCannotFindHost,NSURLErrorDNSLookupFailed].contains(value.code)
    }
    private func drain() {
        wake?.cancel(); wake = nil
        let now = ProcessInfo.processInfo.systemUptime
        recent.removeAll { now - $0 >= window }
        guard active.count < concurrency, !waiting.isEmpty else { return }
        let index = waiting.indices.min { waiting[$0].priority.rawValue < waiting[$1].priority.rawValue }!
        let waiter = waiting[index]
        var delay = max(0, blockedUntil - now)
        if let last = recent.last { delay = max(delay,spacing - (now-last)) }
        let limit = limits[waiter.priority.rawValue]
        if waiter.priority == .alternatives, blockedUntil > now || recent.count >= limit {
            waiting.remove(at:index).continuation.resume(throwing:Deferred.optionalComparison); drain(); return
        }
        if recent.count >= limit { delay = max(delay,(recent[recent.count-limit] + window) - now) }
        if delay > 0 {
            wake = Task { [weak self] in
                do { try await Task.sleep(for:.seconds(max(0.01,delay))) } catch { return }
                self?.drain()
            }
            return
        }
        waiting.remove(at:index); recent.append(now); active.insert(waiter.id)
        waiter.continuation.resume(); drain()
    }
}
