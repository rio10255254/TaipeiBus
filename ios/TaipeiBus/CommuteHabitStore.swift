import SwiftUI
import UserNotifications
import TransitCore

@MainActor
final class CommuteHabitStore: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "commuteSuggestions.enabled")
            if !enabled { clear(); reminders = false }
        }
    }
    @Published private(set) var history = CommutePatterns()
    /// A notification about ten minutes before a weekday trip usually starts; needs `enabled`.
    @Published var reminders: Bool {
        didSet { defaults.set(reminders, forKey: "commuteReminders.enabled") }
    }
    private let defaults: UserDefaults
    private let key = "commuteSuggestions.history.v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "commuteSuggestions.enabled")
        reminders = defaults.bool(forKey: "commuteReminders.enabled")
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

    private static let reminderIDs = (0..<10).map { "commute-reminder-\($0)" }
    /// Weekday notifications for the two most used trips, ten minutes before they usually start; tapping
    /// one opens that trip's routes. Rescheduled when the app opens, so they follow the habit.
    func scheduleReminders(_ journeys: [SavedJourney], now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Self.reminderIDs)
        guard enabled, reminders else { return }
        var ids = Self.reminderIDs.makeIterator()
        for start in history.usualWeekdayStarts(available: Set(journeys.map(\.id)), at: now).prefix(2) {
            guard let journey = journeys.first(where: { $0.id == start.journeyID }) else { continue }
            let minute = (start.minute - 10 + 1440) % 1440
            for weekday in 2...6 {
                guard let id = ids.next() else { return }
                let content = UNMutableNotificationContent()
                content.title = AppText.text("要出發去「%@」了嗎？", journey.title)
                content.body = AppText.text("平常這時候出發，點一下看下一班車。")
                content.userInfo = ["commute": journey.id.uuidString]
                var time = DateComponents(); time.weekday = weekday; time.hour = minute / 60; time.minute = minute % 60
                time.timeZone = AssistantJourneyRequest.calendar.timeZone
                center.add(UNNotificationRequest(identifier: id, content: content,
                                                 trigger: UNCalendarNotificationTrigger(dateMatching: time, repeats: true)))
            }
        }
    }
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
            if habits.enabled {
                Toggle(AppText.text("平日出發前通知我"), isOn: $habits.reminders)
                    .accessibilityIdentifier("commute-reminders-toggle")
                    .onChange(of: habits.reminders) { _, on in
                        guard on else { return }
                        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                    }
            }
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
