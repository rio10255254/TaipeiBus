import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct OfficialNotice: Identifiable, Equatable, Sendable {
    public var id: String { source.absoluteString }
    public let title: String
    public let body: String
    public let source: URL
    public let publishedAt: Date
}

public enum OfficialNotices {
    // Advertised by the RSS link on the Public Transportation Office news page.
    public static let feedURL = URL(string: "https://pto.gov.taipei/OpenData.aspx?SN=EB6F7CBE2BCF295F")!
    public static let newsURL = URL(string: "https://pto.gov.taipei/News.aspx?n=D065CCB1467288C8&sms=72544237BBE4C5F6")!
    public static let maximumBytes = 2_000_000
    public enum Failure: Error { case invalidFeed }
    public static func trusted(_ url: URL) -> Bool {
        url.scheme == "https" && ["pto.gov.taipei", "www.pto.gov.taipei"].contains(url.host?.lowercased() ?? "") &&
            url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
    public static func parse(_ data: Data) throws -> [OfficialNotice] {
        guard !data.isEmpty, data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw Failure.invalidFeed
        }
        let delegate = Reader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.rss, !delegate.values.isEmpty else { throw Failure.invalidFeed }
        var seen = Set<String>()
        return delegate.values.filter { seen.insert($0.id).inserted }.sorted { $0.publishedAt > $1.publishedAt }
    }
    private final class Reader: NSObject, XMLParserDelegate {
        var rss = false
        var values: [OfficialNotice] = []
        private var inItem = false
        private var field = ""
        private var fields: [String: String] = [:]
        private let date: DateFormatter = {
            let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX")
            value.timeZone = TimeZone(secondsFromGMT: 0); value.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return value
        }()
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "rss" { rss = true }
            if name == "item" { inItem = true; fields = [:] }
            if inItem, ["title", "link", "description", "pubDate"].contains(name) { field = name }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inItem, !field.isEmpty { fields[field, default: ""] += string }
        }
        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            if let text = String(data: block, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == field { field = "" }
            guard name == "item" else { return }
            inItem = false
            let title = (fields["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let html = fields["description"] ?? ""
            guard values.count < 100, !title.isEmpty, title.count <= 500, html.count <= 100_000,
                  let url = URL(string: (fields["link"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)), trusted(url),
                  url.path.lowercased() == "/news_content.aspx",
                  let published = date.date(from: (fields["pubDate"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            let body = plainText(html)
            guard !body.isEmpty else { return }
            values.append(OfficialNotice(title: title, body: body, source: url, publishedAt: published))
        }
    }
    /// Plain text only: never render provider HTML, load its images, or execute scripts.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|li|h[1-6]|tr)\s*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        let pattern = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);"#)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let keyRange = Range(match.range(at: 1), in: text) else { continue }
            let key = String(text[keyRange])
            var value = entities[key]
            if key.hasPrefix("#") {
                let number = key.hasPrefix("#x") ? UInt32(key.dropFirst(2), radix: 16) : UInt32(key.dropFirst())
                value = number.flatMap(UnicodeScalar.init).map(String.init)
            }
            if let value { text.replaceSubrange(whole, with: value) }
        }
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
