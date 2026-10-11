import SwiftUI
import TransitCore

enum RoutePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case balanced, faster, lessWalking, fewerTransfers
    var id: String { rawValue }
    var title: String {
        AppText.text(self == .balanced ? "推薦" : self == .faster ? "時間優先" : self == .lessWalking ? "少走路" : "少轉乘")
    }
    func applying(to base: LiveSettings.Planning) -> LiveSettings.Planning {
        var value = base
        switch self {
        case .balanced: break
        case .faster: value.walkingWeight = 1; value.waitingWeight = 1; value.transferPenaltySeconds = 120
        case .lessWalking: value.walkingWeight = 2.8; value.waitingWeight = 1; value.transferPenaltySeconds = 420
        case .fewerTransfers: value.walkingWeight = 1.2; value.waitingWeight = 1; value.transferPenaltySeconds = 900
        }
        return value
    }
}

struct SavedJourney: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var symbol: String
    var origin: TravelPlace?
    var destination: TravelPlace
    var preference: RoutePreference
    var updatedAt: Date
    static let symbols = ["house.fill","briefcase.fill","book.fill","bag.fill","mappin"]
    var valid: Bool {
        !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && title.count <= 40 &&
        Self.symbols.contains(symbol) && destination.coordinate.isInServiceArea &&
        (origin?.coordinate.isInServiceArea ?? true)
    }
}

@MainActor
final class CommuteLibrary: ObservableObject {
    @Published private(set) var journeys: [SavedJourney] = []
    @Published var preference: RoutePreference = .balanced { didSet { save() } }
    private let defaults: UserDefaults
    private let key = "proCommuteLibrary.v1"
    private struct Storage: Codable { var journeys: [SavedJourney]; var preference: RoutePreference }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let bytes = defaults.data(forKey:key), bytes.count <= 262_144,
              let value = try? JSONDecoder().decode(Storage.self,from:bytes) else { return }
        var seen: Set<UUID> = []
        journeys = Array(value.journeys.filter { $0.valid && seen.insert($0.id).inserted }.prefix(50))
        preference = value.preference
    }
    @discardableResult
    func store(title: String, symbol: String, origin: TravelPlace?, destination: TravelPlace,
               preference: RoutePreference, replacing id: UUID? = nil) -> Bool {
        let item = SavedJourney(id:id ?? UUID(),title:String(title.trimmingCharacters(in:.whitespacesAndNewlines).prefix(40)),
            symbol:symbol,origin:origin,destination:destination,preference:preference,updatedAt:Date())
        guard item.valid else { return false }
        if let index = journeys.firstIndex(where:{ $0.id == item.id }) { journeys[index] = item }
        else { guard journeys.count < 50 else { return false }; journeys.append(item) }
        save(); return true
    }
    func remove(_ ids: Set<UUID>) { journeys.removeAll { ids.contains($0.id) }; save() }
    func move(from offsets: IndexSet, to destination: Int) { journeys.move(fromOffsets:offsets,toOffset:destination); save() }
    private func save() {
        if let bytes = try? JSONEncoder().encode(Storage(journeys:journeys,preference:preference)) {
            defaults.set(bytes,forKey:key)
        }
    }
}
