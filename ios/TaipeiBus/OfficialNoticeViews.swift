import SwiftUI
import TransitCore

private final class NoticeRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(OfficialNotices.trusted) == true ? request : nil)
    }
}

@MainActor private final class OfficialNoticeStore: ObservableObject {
    @Published var notices: [OfficialNotice] = []
    @Published var loading = false
    @Published var failed = false
    @Published var fetchedAt: Date?
    func load() async {
        guard !loading else { return }
        loading = true; failed = false
        defer { loading = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoticeRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(from: OfficialNotices.feedURL)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url.map(OfficialNotices.trusted) == true else { throw OfficialNotices.Failure.invalidFeed }
            var data = Data()
            for try await byte in stream {
                guard data.count < OfficialNotices.maximumBytes else { throw OfficialNotices.Failure.invalidFeed }
                data.append(byte)
            }
            try Task.checkCancellation()
            notices = try OfficialNotices.parse(data); fetchedAt = Date()
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

struct OfficialNoticesView: View {
    @StateObject private var store = OfficialNoticeStore()
    @State private var query = ""
    private var filtered: [OfficialNotice] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? store.notices : store.notices.filter {
            ($0.title + "\n" + $0.body).range(of: text, options: [.caseInsensitive, .widthInsensitive]) != nil
        }
    }
    var body: some View {
        List {
            Section {
                Text(AppText.text("來源：臺北市公共運輸處新聞稿。發布日期不等於管制日期；請核對原文及附件。公告可能包含已結束的措施，未列出也不代表沒有異動。"))
                    .font(.footnote).foregroundStyle(.secondary)
                if let date = store.fetchedAt { Text(AppText.text("取得時間：%@", date.formatted(date: .abbreviated, time: .shortened))) }
                if store.failed {
                    Text(AppText.text("無法更新公告；下列內容可能不是最新資料，請查看官網。"))
                    Button(AppText.text("重試")) { Task { await store.load() } }
                }
                Link(AppText.text("公運處公告原文"), destination: OfficialNotices.newsURL)
            }
            if filtered.isEmpty {
                // The first load holds the list's shape; afterwards say why nothing is listed.
                if store.loading {
                    LoadingRows(count: 4, label: AppText.text("載入公告中"))
                        .listRowSeparator(.hidden).accessibilityIdentifier("notices-loading")
                } else if !store.failed {
                    EmptyStateView(symbol: query.isEmpty ? "checkmark.circle" : "magnifyingglass",
                                   title: query.isEmpty ? AppText.text("目前沒有交通公告") : AppText.text("找不到「%@」", query),
                                   message: AppText.text(query.isEmpty ? "公運處發布新的公告後會列在這裡。" : "試試路線號碼、站名或道路名稱。"))
                        .listRowSeparator(.hidden).accessibilityIdentifier("notices-empty")
                }
            } else if store.loading { ProgressView() }
            ForEach(filtered) { notice in
                NavigationLink {
                    OfficialNoticeDetail(notice: notice)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(notice.title)
                        Text(notice.publishedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle(AppText.text("交通公告"))
            .searchable(text: $query, prompt: AppText.text("路線或公告關鍵字"))
            .task { if store.fetchedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true { await store.load() } }
            .refreshable { await store.load() }
    }
}

private struct OfficialNoticeDetail: View {
    let notice: OfficialNotice
    @State private var excerpts: [String] = []
    @State private var credit: String?
    @State private var busy = false
    @State private var failed = false
    @State private var operation: Task<Void, Never>?
    private var document: NoticeExcerpt { NoticeExcerpt(body: notice.body) }
    var body: some View {
        List {
            Section {
                Text(notice.title).font(.headline)
                Text(notice.publishedAt.formatted(date: .abbreviated, time: .shortened))
                Link(AppText.text("完整公告與附件"), destination: notice.source)
            }
            Section {
                if OnDeviceJourneyAssistant.unavailableReason(language: .traditionalChinese) != nil, !OnlineJourneyReader.enabled {
                    Text(AppText.text("重點摘錄目前無法使用，仍可閱讀下方全文。"))
                }
                else if document.canSummarize {
                    Button(AppText.text("擷取原文重點")) {
                        operation?.cancel(); busy = true; failed = false
                        operation = Task { @MainActor in
                            do {
                                let result = try await OnDeviceJourneyAssistant.excerpt(document, language: .traditionalChinese)
                                try Task.checkCancellation(); excerpts = result.paragraphs; credit = result.credit
                            } catch { if !Task.isCancelled { failed = true } }
                            busy = false
                        }
                    }.disabled(busy)
                }
                if busy { ProgressView() }
                if failed { Text(AppText.text("暫時無法擷取重點，請閱讀下方原文。")) }
                ForEach(Array(excerpts.enumerated()), id: \.offset) { Text($0.element) }
                if let credit, !excerpts.isEmpty { ModelCredit(text: AppText.text("由 %@ 產生", credit)) }
            } header: { Text(AppText.text("原文重點摘錄")) }
            footer: { Text(AppText.text("模型僅選取原文段落（同意線上理解時由 Anthropic 的 Claude 或 Groq 上的開源模型，否則在手機上），可能省略重要條件；請務必核對全文、管制日期、方向及附件。摘錄不會更動路線規劃或到站時間。")) }
            Section(AppText.text("公告全文")) { Text(notice.body).textSelection(.enabled) }
        }.navigationTitle(AppText.text("交通公告")).navigationBarTitleDisplayMode(.inline)
            .onDisappear { operation?.cancel() }
    }
}
