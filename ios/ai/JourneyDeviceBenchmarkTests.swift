import XCTest
import TransitCore
@testable import TaipeiBus

/// Separate device-only scheme. Never reports simulator/stub inference as a model run.
/// The measurement itself is JourneyBenchmark, shared with the tester page in the app.
@MainActor final class JourneyDeviceBenchmarkTests: XCTestCase {
    private func attach<T: Encodable>(_ value: T, name: String) throws {
        let attachment = XCTAttachment(data: try JourneyBenchmark.encoded(value), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
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
        let bundle = Bundle(for: Self.self)
        let data = try JourneyBenchmark.corpusData(bundle: bundle)
        let corpus = try JSONDecoder().decode(JourneyBenchmark.Corpus.self, from: data)
        XCTAssertTrue((50...100).contains(corpus.cases.count))
        let sourceURL = try XCTUnwrap(bundle.url(forResource: "journey-build", withExtension: "json"))
        let build = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: sourceURL))
        let source = JourneyBenchmark.source(corpus: data).merging(build) { _, new in new }
        let started = Date()
        var rows: [JourneyBenchmark.Row] = []
        for sample in corpus.cases {
            let row = await JourneyBenchmark.run(sample)
            rows.append(row)
            try attach(row, name: "journey-\(sample.id)")
        }
        try attach(JourneyBenchmark.report(rows, corpus: corpus, source: source, startedAt: started), name: "journey-device-report")
        // This is a baseline measurement, not an accuracy acceptance threshold.
        XCTAssertEqual(rows.count, corpus.cases.count)
    }
}
