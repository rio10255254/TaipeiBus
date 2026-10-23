import SwiftUI
import UIKit
import StoreKit
import CryptoKit
import TransitCore

/// Measures the on-device journey reader against ios/ai/journey-corpus.json on the real model.
/// The tester page and the device XCTest share this code, so both produce the same report that
/// ios/ai/journey-report.py reads. Saved journeys are fixed fictional fixtures; the user's own
/// library, history and settings are never read or changed.
@MainActor
enum JourneyBenchmark {
    struct Expected: Codable {
        let destination: [String]
        let origin: [String]
        let preference: String
        let time: String
    }
    struct FollowUp: Codable { let optionContains: [String]; let expected: Expected }
    struct Case: Codable {
        let id: String
        let text: String
        let scenario: String
        let now: String
        let expected: Expected
        let expectsQuestion: Bool
        let requiresSavedTool: Bool
        let followUp: FollowUp?
    }
    struct Corpus: Codable { let schemaVersion: Int; let cases: [Case] }
    struct Observation: Encodable {
        let request: AssistantJourneyRequest
        let question: AssistantClarification?
        let destinations: [TravelPlace]
        let origins: [TravelPlace]
        init(_ turn: AssistantJourneyTurn) {
            request = turn.request; question = turn.clarification
            destinations = turn.destinationCandidates; origins = turn.originCandidates
        }
    }
    struct Row: Encodable {
        let id: String
        let text: String
        let referenceDate: String
        let scenario: String
        let expected: Expected
        let followUpExpected: Expected?
        var observed: Observation?
        var fieldCorrect: [String: Bool] = [:]
        var fieldAccuracy: Double = 0
        var questionCorrect = false
        var savedToolCorrect = false
        var selectedOption: String?
        var followUpObserved: Observation?
        var followUpCorrect: [String: Bool]?
        var toolCalls: [String] = []
        var error: String?
        var elapsedSeconds: Double = 0
    }
    struct Report: Encodable {
        let schemaVersion: Int
        let promptVersion: String
        let device: String
        let operatingSystem: String
        let language: String
        let startedAt: Date
        let completedAt: Date
        let source: [String: String]
        let cases: [Row]
        let fieldAccuracy: [String: Double]
        let allFieldsCorrectRate: Double
        let errors: Int
    }
    static let fields = ["destination", "origin", "preference", "time"]

    static func corpusData(bundle: Bundle = .main) throws -> Data {
        guard let url = bundle.url(forResource: "journey-corpus", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf: url)
    }
    /// Identifies the build and corpus a report came from.
    static func source(corpus: Data) -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        return ["appVersion": info["CFBundleShortVersionString"] as? String ?? "",
                "build": info["CFBundleVersion"] as? String ?? "",
                "corpusSHA256": SHA256.hash(data: corpus).map { String(format: "%02x", $0) }.joined()]
    }

    /// Tester builds only: Debug builds, Xcode installs and TestFlight. App Store installs never show it.
    static func testerBuild() async -> Bool {
#if DEBUG
        return true
#else
        guard let result = try? await AppTransaction.shared, case .verified(let transaction) = result else { return false }
        return transaction.environment == .sandbox || transaction.environment == .xcode
#endif
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_TW"))
            .replacingOccurrences(of: "臺", with: "台").filter { !$0.isWhitespace }
    }
    static func score(_ turn: AssistantJourneyTurn, expected: Expected) -> [String: Bool] {
        let request = turn.request
        func place(_ text: String, _ options: [String], _ status: AssistantFieldStatus) -> Bool {
            options.isEmpty ? status == .needsConfirmation : options.contains { normalized($0) == normalized(text) }
        }
        let time: Bool
        switch expected.time {
        case "confirm": time = request.review.time == .needsConfirmation
        case "none": time = request.arriveBy == nil && request.timeDescription.isEmpty
        default: time = request.arriveBy == ISO8601DateFormatter().date(from: expected.time)
        }
        return ["destination": place(request.destination, expected.destination, request.review.destination),
                "origin": place(request.origin, expected.origin, request.review.origin),
                "preference": expected.preference == "confirm" ? request.review.preference == .needsConfirmation : request.preference.rawValue == expected.preference,
                "time": time]
    }
    static func fixtures(_ scenario: String) -> [SavedJourney] {
        guard scenario != "none" else { return [] }
        func journey(_ title: String, _ symbol: String, _ name: String, _ coordinate: Coordinate,
                     _ preference: RoutePreference = .balanced) -> SavedJourney {
            SavedJourney(id: UUID(), title: title, symbol: symbol, origin: nil,
                destination: TravelPlace(name: name, address: "測試資料，非私人地址", coordinate: coordinate),
                preference: preference, updatedAt: Date(timeIntervalSince1970: 0))
        }
        var values = [journey("家", "house.fill", "測試住家（古亭）", Coordinate(latitude: 25.026, longitude: 121.522)),
                      journey("公司", "briefcase.fill", "測試公司（市政府）", Coordinate(latitude: 25.037, longitude: 121.565), .faster)]
        if scenario == "twoHomes" {
            values.append(journey("另一個家", "house.fill", "測試住家（板橋）", Coordinate(latitude: 25.014, longitude: 121.463)))
        }
        if scenario == "twoOffices" {
            values.append(journey("公司分部", "briefcase.fill", "測試公司（南港）", Coordinate(latitude: 25.052, longitude: 121.607), .lessWalking))
        }
        if scenario == "named" {
            values.append(journey("週末讀書", "book.fill", "國立臺灣大學", Coordinate(latitude: 25.017, longitude: 121.540), .lessWalking))
        }
        return values
    }
    static func deviceModel() -> String {
        var info = utsname(); uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }

    /// One utterance in a new session; a corpus follow-up answers in the same session.
    static func run(_ sample: Case) async -> Row {
        let start = Date()
        var row = Row(id: sample.id, text: sample.text, referenceDate: sample.now, scenario: sample.scenario,
                      expected: sample.expected, followUpExpected: sample.followUp?.expected)
        row.fieldCorrect = Dictionary(uniqueKeysWithValues: fields.map { ($0, false) })
        let context = JourneyAssistantContext(journeys: fixtures(sample.scenario)) { query in
            let search = PlaceSearch(); search.setContext(.taipei)
            return try await search.find(text: query, queryLimit: 2, timeout: 4)
        }
        do {
            guard let now = ISO8601DateFormatter().date(from: sample.now) else { throw CocoaError(.coderInvalidValue) }
            let session = try OnDeviceJourneyAssistant.conversation(context: context, language: .traditionalChinese)
            let turn = try await session.begin(sample.text, at: now)
            row.observed = Observation(turn); row.fieldCorrect = score(turn, expected: sample.expected)
            row.fieldAccuracy = Double(row.fieldCorrect.values.filter { $0 }.count) / Double(fields.count)
            row.questionCorrect = (turn.clarification != nil) == sample.expectsQuestion
            if let followUp = sample.followUp {
                if let question = turn.clarification,
                   let index = question.options.firstIndex(where: { option in followUp.optionContains.contains { normalized(option).contains(normalized($0)) } }) {
                    row.selectedOption = question.options[index]
                    let next = try await session.answer(option: index)
                    row.followUpObserved = Observation(next); row.followUpCorrect = score(next, expected: followUp.expected)
                } else {
                    row.error = "No offered option matches the corpus follow-up; manual review required."
                    row.followUpCorrect = Dictionary(uniqueKeysWithValues: fields.map { ($0, false) })
                }
            }
        } catch { row.error = String(describing: error) }
        row.toolCalls = context.toolCalls
        row.savedToolCorrect = !sample.requiresSavedTool || context.toolCalls.contains { $0.hasPrefix("listSavedJourneys") }
        row.elapsedSeconds = Date().timeIntervalSince(start)
        return row
    }

    static func report(_ rows: [Row], corpus: Corpus, source: [String: String], startedAt: Date) -> Report {
        let count = Double(max(rows.count, 1))
        let accuracy = Dictionary(uniqueKeysWithValues: fields.map { field in
            (field, Double(rows.filter { $0.fieldCorrect[field] == true }.count) / count)
        })
        return Report(schemaVersion: corpus.schemaVersion, promptVersion: OnDeviceJourneyAssistant.promptVersion,
            device: deviceModel(), operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            language: "zh-Hant", startedAt: startedAt, completedAt: Date(), source: source, cases: rows,
            fieldAccuracy: accuracy, allFieldsCorrectRate: Double(rows.filter { $0.fieldAccuracy == 1 }.count) / count,
            errors: rows.filter { $0.error != nil }.count)
    }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

/// Tester-only page: runs the corpus on this iPhone's model and shares the report file.
struct JourneyBenchmarkView: View {
    @State private var corpus: JourneyBenchmark.Corpus?
    @State private var source: [String: String] = [:]
    @State private var rows: [JourneyBenchmark.Row] = []
    @State private var startedAt = Date()
    @State private var running: Task<Void, Never>?
    @State private var file: URL?
    @State private var failure: String?
    private var unavailable: String? { OnDeviceJourneyAssistant.unavailableReason(language: .traditionalChinese) }

    var body: some View {
        List {
            Section {
                Text(AppText.text("在這支 iPhone 的裝置端模型上逐句測試內建的行程語句，使用虛構的常用行程，不讀取或修改你的資料。地點搜尋仍使用 Apple 地圖。"))
                if let unavailable { Text(unavailable).foregroundStyle(.secondary) }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            if let corpus {
                Section {
                    ProgressView(value: Double(rows.count), total: Double(corpus.cases.count)) {
                        Text("\(rows.count) / \(corpus.cases.count)").monospacedDigit()
                    }
                    if !rows.isEmpty {
                        let correct = rows.filter { $0.fieldAccuracy == 1 }.count
                        Text(AppText.text("四欄全對：%@", "\(correct) / \(rows.count)")).monospacedDigit()
                    }
                    if running == nil {
                        Button(rows.isEmpty ? AppText.text("開始測試") : AppText.text("重新測試")) { start(corpus) }
                            .disabled(unavailable != nil).accessibilityIdentifier("ai-benchmark-start")
                    } else {
                        Button(AppText.text("停止"), role: .destructive) { running?.cancel() }
                    }
                    if let file, running == nil {
                        ShareLink(item: file) { Label(AppText.text("分享測試報告"), systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("ai-benchmark-share")
                    }
                } footer: {
                    Text(AppText.text("測試期間請保持 App 在前景。報告為 JSON 檔，可傳回電腦用 journey-report.py 整理。"))
                }
            }
        }
        .navigationTitle(AppText.text("AI 測試")).navigationBarTitleDisplayMode(.inline)
        .task {
            guard corpus == nil else { return }
            do {
                let data = try JourneyBenchmark.corpusData()
                corpus = try JSONDecoder().decode(JourneyBenchmark.Corpus.self, from: data)
                source = JourneyBenchmark.source(corpus: data)
            } catch { failure = String(describing: error) }
        }
        .onDisappear { running?.cancel() }
    }

    private func start(_ corpus: JourneyBenchmark.Corpus) {
        rows = []; file = nil; failure = nil; startedAt = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        running = Task {
            for sample in corpus.cases {
                if Task.isCancelled { break }
                rows.append(await JourneyBenchmark.run(sample))
            }
            save(corpus)
            UIApplication.shared.isIdleTimerDisabled = false
            running = nil
        }
    }
    /// Partial runs are saved too; journey-report.py reports them as incomplete.
    private func save(_ corpus: JourneyBenchmark.Corpus) {
        guard !rows.isEmpty else { return }
        let report = JourneyBenchmark.report(rows, corpus: corpus, source: source, startedAt: startedAt)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journey-device-report-\(formatter.string(from: startedAt)).json")
        do { try JourneyBenchmark.encoded(report).write(to: url, options: .atomic); file = url }
        catch { failure = String(describing: error) }
    }
}
