import Foundation

/// A model may select source paragraphs, never write new disruption facts.
/// Fetching/authenticating the official document belongs to the notice provider.
public struct NoticeExcerpt: Sendable {
    public let paragraphs: [String]
    public init(body: String) {
        paragraphs = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    /// Bound the context before handing any official text to a small local model.
    /// Larger announcements stay available in full without a generated excerpt.
    public var canSummarize: Bool {
        (2...40).contains(paragraphs.count) && paragraphs.joined().count <= 1800
    }
    public enum Failure: Error { case invalidSelection }
    public func selecting(_ indices: [Int]) throws -> [String] {
        guard canSummarize, (1...3).contains(indices.count), Set(indices).count == indices.count,
              indices.allSatisfy({ paragraphs.indices.contains($0) }) else { throw Failure.invalidSelection }
        // Preserve source order, dates, negations and qualifications within each paragraph.
        return indices.sorted().map { paragraphs[$0] }
    }
}
