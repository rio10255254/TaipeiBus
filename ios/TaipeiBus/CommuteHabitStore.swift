import SwiftUI
import TransitCore

@MainActor
final class CommuteHabitStore: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "commuteSuggestions.enabled")
            if !enabled { clear() }
        }
    }
    @Published private(set) var history = CommutePatterns()
    private let defaults: UserDefaults
    private let key = "commuteSuggestions.history.v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "commuteSuggestions.enabled")
        if enabled, let bytes = defaults.data(forKey: key), bytes.count <= 262_144,
           var value = try? JSONDecoder().decode(CommutePatterns.self, from: bytes) {
            value.prune(at: Date()); history = value
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        } else { defaults.removeObject(forKey: key) }
    }
    func record(_ id: UUID, available: Set<UUID>, at date: Date = Date()) {
        guard enabled, available.contains(id) else { return }
        var next = history; next.prune(at: date, keeping: available); next.record(journeyID: id, at: date)
        guard next != history else { return }
        history = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
    }
    func clear() { history = CommutePatterns(); defaults.removeObject(forKey: key) }
    func prune(available: Set<UUID>, at date: Date = Date()) {
        var next = history; next.prune(at: date, keeping: available)
        guard next != history else { return }
        history = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
    }
}

struct CommuteHabitSettings: View {
    @ObservedObject var habits: CommuteHabitStore
    var body: some View {
        Section {
            Toggle(AppText.text("依通勤習慣提示常用行程"), isOn: $habits.enabled)
                .accessibilityIdentifier("commute-suggestions-toggle")
            Button(AppText.text("清除通勤提示紀錄"), role: .destructive) { habits.clear() }
                .disabled(habits.history.events.isEmpty).accessibilityIdentifier("commute-suggestions-clear")
        } header: { Text(AppText.text("通勤提示")) }
        footer: { Text(AppText.text("開啟後只在手機記錄已儲存行程的開始時間，最多保留 42 天。相近時段至少使用三天才提示；關閉即清除紀錄，不影響已儲存的行程。")) }
    }
}

struct CommuteHabitSuggestions: View {
    @ObservedObject var habits: CommuteHabitStore
    @ObservedObject var library: CommuteLibrary
    let choose: (SavedJourney) -> Void
    var body: some View {
        if habits.enabled {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let ids = habits.history.suggestions(available: Set(library.journeys.map(\.id)), at: timeline.date)
                if !ids.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppText.text("這個時段常用的行程")).font(.subheadline.weight(.semibold))
                        ForEach(ids, id: \.self) { id in
                            if let saved = library.journeys.first(where: { $0.id == id }) {
                                Button { choose(saved) } label: {
                                    Label(saved.title, systemImage: saved.symbol).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }.accessibilityIdentifier("commute-suggestion-" + id.uuidString)
                            }
                        }
                    }.accessibilityIdentifier("commute-suggestions")
                }
                Color.clear.frame(height: 0).onChange(of: timeline.date, initial: true) { _, date in
                    habits.prune(available: Set(library.journeys.map(\.id)), at: date)
                }
            }
            .onChange(of: library.journeys.map(\.id)) { _, ids in habits.prune(available: Set(ids)) }
        }
    }
}
