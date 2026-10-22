import XCTest
import UIKit
import TransitCore
@testable import TaipeiBus

/// Separate device-only scheme. Never reports simulator/stub inference as a model run.
@MainActor final class JourneyDeviceBenchmarkTests: XCTestCase {
    private struct Expected: Codable {
        let destination: [String]
        let origin: [String]
        let preference: String
        let time: String
    }
    private struct FollowUp: Decodable { let optionContains: [String]; let expected: Expected }
    private struct Case: Decodable {
        let id: String
        let text: String
        let scenario: String
        let now: String
        let expected: Expected
        let expectsQuestion: Bool
        let requiresSavedTool: Bool
        let followUp: FollowUp?
    }
    private struct Corpus: Decodable { let schemaVersion: Int; let cases: [Case] }
    private struct Observation: Encodable {
        let request: AssistantJourneyRequest
        let question: AssistantClarification?
        let destinations: [TravelPlace]
        let origins: [TravelPlace]
        init(_ turn: AssistantJourneyTurn) {
            request = turn.request; question = turn.clarification
            destinations = turn.destinationCandidates; origins = turn.originCandidates
        }
    }
    private struct Row: Encodable {
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
    private struct Report: Encodable {
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
    private let fields = ["destination", "origin", "preference", "time"]
    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_TW"))
            .replacingOccurrences(of: "臺", with: "台").filter { !$0.isWhitespace }
    }
    private func score(_ turn: AssistantJourneyTurn, expected: Expected) -> [String: Bool] {
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
    private func fixtures(_ scenario: String) -> [SavedJourney] {
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
    private func attach<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let attachment = XCTAttachment(data: try encoder.encode(value), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func deviceModel() -> String {
        var info = utsname(); uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
    func testRealModelCorpus() async throws {
#if targetEnvironment(simulator)
        let physicalDevice = false
#else
        let physicalDevice = true
#endif
        guard physicalDevice else {
            throw XCTSkip("Requires a physical Apple Intelligence iPhone. No inference or accuracy was measured.")
        }
        guard !ProcessInfo.processInfo.arguments.contains("--test-ai-review") else {
            throw XCTSkip("UI fixtures cannot be used for model accuracy measurements.")
        }
        if let reason = OnDeviceJourneyAssistant.unavailableReason(language: .traditionalChinese) {
            throw XCTSkip("Real model unavailable: \(reason). No accuracy was measured.")
        }
        executionTimeAllowance = 5400
        let priorLanguage = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set(AppLanguage.traditionalChinese.rawValue, forKey: AppLanguage.preferenceKey)
        defer {
            if let priorLanguage { UserDefaults.standard.set(priorLanguage, forKey: AppLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "journey-corpus", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertTrue((50...100).contains(corpus.cases.count))
        let sourceURL = try XCTUnwrap(bundle.url(forResource: "journey-build", withExtension: "json"))
        let source = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: sourceURL))
        let started = Date()
        var rows: [Row] = []
        for sample in corpus.cases {
            let start = Date()
            var row = Row(id: sample.id, text: sample.text, referenceDate: sample.now, scenario: sample.scenario,
                          expected: sample.expected, followUpExpected: sample.followUp?.expected)
            row.fieldCorrect = Dictionary(uniqueKeysWithValues: fields.map { ($0, false) })
            let context = JourneyAssistantContext(journeys: fixtures(sample.scenario)) { query in
                let search = PlaceSearch(); search.setContext(.taipei)
                return try await search.find(text: query)
            }
            do {
                let session = try OnDeviceJourneyAssistant.conversation(context: context, language: .traditionalChinese)
                let turn = try await session.begin(sample.text, at: XCTUnwrap(ISO8601DateFormatter().date(from: sample.now)))
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
            row.savedToolCorrect = !sample.requiresSavedTool || context.toolCalls.contains("listSavedJourneys")
            row.elapsedSeconds = Date().timeIntervalSince(start)
            rows.append(row)
            try attach(row, name: "journey-\(sample.id)")
        }
        let accuracy = Dictionary(uniqueKeysWithValues: fields.map { field in
            (field, Double(rows.filter { $0.fieldCorrect[field] == true }.count) / Double(rows.count))
        })
        let report = Report(schemaVersion: corpus.schemaVersion, promptVersion: OnDeviceJourneyAssistant.promptVersion,
            device: deviceModel(), operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            language: "zh-Hant", startedAt: started, completedAt: Date(), source: source, cases: rows,
            fieldAccuracy: accuracy, allFieldsCorrectRate: Double(rows.filter { $0.fieldAccuracy == 1 }.count) / Double(rows.count),
            errors: rows.filter { $0.error != nil }.count)
        try attach(report, name: "journey-device-report")
        // This is a baseline measurement, not an accuracy acceptance threshold.
        XCTAssertEqual(rows.count, corpus.cases.count)
    }
}
