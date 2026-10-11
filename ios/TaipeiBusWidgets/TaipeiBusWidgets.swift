import ActivityKit
import StoreKit
import SwiftUI
import WidgetKit
import TransitCore

@main
struct TaipeiBusWidgetBundle: WidgetBundle {
    var body: some Widget {
        CommuteWidget()
        RideLiveActivity()
    }
}

private var deviceLanguage: AppLanguage { AppLanguage.deviceDefault(Locale.preferredLanguages) }

// MARK: Saved trips on the Home Screen and Lock Screen

struct CommuteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CommuteWidget", provider: CommuteProvider()) { entry in
            CommuteWidgetContainer(entry: entry)
        }
        .configurationDisplayName(Text(AppText.text("常用行程", language: deviceLanguage)))
        .description(Text(AppText.text("常用行程的下一班車與出門時間", language: deviceLanguage)))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

private struct CommuteWidgetContainer: View {
    @Environment(\.widgetFamily) private var family
    let entry: CommuteEntry
    var body: some View {
        CommuteWidgetView(entry: entry, family: family)
            .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }
}

struct CommuteProvider: TimelineProvider {
    func placeholder(in context: Context) -> CommuteEntry { Self.sample }

    func getSnapshot(in context: Context, completion: @escaping (CommuteEntry) -> Void) {
        if context.isPreview && SharedStore.commutes()?.commutes.isEmpty != false { completion(Self.sample); return }
        Task { completion(await Self.entries(at: Date()).first ?? Self.sample) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CommuteEntry>) -> Void) {
        Task {
            let now = Date()
            let entries = await Self.entries(at: now)
            // Bus times move; ask the feed again in ten minutes. Metro intervals and locked or
            // empty widgets only need an occasional refresh.
            let live = entries.first.map { !$0.locked && $0.commutes.contains { $0.ride?.metro == false } } ?? false
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(live ? 600 : 3600))))
        }
    }

    static func entries(at now: Date) async -> [CommuteEntry] {
        let payload = SharedStore.commutes()
        let language = payload.flatMap { AppLanguage(rawValue: $0.language) } ?? deviceLanguage
        let commutes = Array((payload?.commutes ?? []).prefix(CommuteWidgetPayload.maximumCommutes))
        guard await ProAccess.entitled(payload) else {
            return [CommuteEntry(date: now, language: language, locked: true, commutes: commutes, timings: [:])]
        }
        let result = await EstimateLookup.timings(for: commutes, now: now)
        return (0..<15).map { minute in
            CommuteEntry(date: now.addingTimeInterval(Double(minute) * 60), language: language, locked: false,
                         commutes: commutes, timings: result.timings, feedFailed: result.failed)
        }
    }

    static var sample: CommuteEntry {
        let sign = RouteSign(text: "307", color: "#1F6FD1", darkInk: false)
        let commute = CommuteWidgetPayload.Commute(id: "sample", title: AppText.text("回家", language: deviceLanguage), symbol: "house.fill",
            destination: "", ride: .init(metro: false, sign: sign, routeKey: "", stopID: "", stopName: AppText.text("上車站", language: deviceLanguage),
                                         toward: "", walkSeconds: 240))
        return CommuteEntry(date: Date(), language: deviceLanguage, locked: false, commutes: [commute],
                            timings: ["sample": CommuteTiming(arrival: Date().addingTimeInterval(720))])
    }
}

/// Pro comes from Apple's verified entitlements, as in the app. The app's last known period end
/// covers a moment when StoreKit has not answered the extension yet.
enum ProAccess {
    static func entitled(_ payload: CommuteWidgetPayload?) async -> Bool {
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productType == .autoRenewable,
                  transaction.productID.hasPrefix("com.rio10255254.TaipeiBus.pro."),
                  transaction.revocationDate == nil else { continue }
            if (transaction.expirationDate ?? .distantFuture) > Date() { return true }
        }
        return (payload?.proUntil ?? .distantPast) > Date()
    }
}

/// Reads only the saved stops out of the city's public arrival file (about 160 KB compressed),
/// without decoding the whole file into memory-hungry objects.
enum EstimateLookup {
    static let url = URL(string: "https://tcgbusfs.blob.core.windows.net/blobbus/GetEstimateTime.gz")!

    static func timings(for commutes: [CommuteWidgetPayload.Commute], now: Date) async -> (timings: [String: CommuteTiming], failed: Bool) {
        let wanted = commutes.compactMap { commute in commute.ride.flatMap { $0.metro || $0.routeKey.isEmpty ? nil : (commute.id, $0) } }
        guard !wanted.isEmpty else { return ([:], false) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        guard let (raw, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, let data = inflate(raw),
              let updated = updateTime(data), now.timeIntervalSince(updated) < 600 else { return ([:], true) }
        var timings: [String: CommuteTiming] = [:]
        for (id, ride) in wanted {
            guard let value = estimate(in: data, route: ride.routeKey, stop: ride.stopID) else { continue }
            timings[id] = value >= 0 ? CommuteTiming(arrival: updated.addingTimeInterval(Double(value))) : CommuteTiming(status: value)
        }
        return (timings, false)
    }

    static func inflate(_ data: Data) -> Data? {
        guard data.starts(with: [0x1f, 0x8b]) else { return data }
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = data.withUnsafeBytes { bytes in
            TaipeiBusInflateGzip(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &output, &length)
        }
        guard status == 0, let output else { return nil }
        defer { TaipeiBusFreeBytes(output) }
        return Data(bytes: output, count: length)
    }

    static func updateTime(_ data: Data) -> Date? {
        guard let start = data.range(of: Data("\"UpdateTime\":\"".utf8)),
              let end = data[start.upperBound..<min(data.endIndex, start.upperBound + 40)].firstIndex(of: UInt8(ascii: "\"")),
              let text = String(data: data[start.upperBound..<end], encoding: .utf8) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.date(from: text)
    }

    /// Finds each `"StopID":<stop>` and decodes just its enclosing record.
    static func estimate(in data: Data, route: String, stop: String) -> Int? {
        let open = UInt8(ascii: "{"), close = UInt8(ascii: "}")
        for needle in ["\"StopID\":" + stop, "\"StopID\":\"" + stop + "\""] {
            var cursor = data.startIndex
            let pattern = Data(needle.utf8)
            while let match = data.range(of: pattern, in: cursor..<data.endIndex) {
                cursor = match.upperBound
                if match.upperBound < data.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(data[match.upperBound]) { continue }
                let lower = max(data.startIndex, match.lowerBound - 160), upper = min(data.endIndex, match.upperBound + 160)
                guard let begin = data[lower..<match.lowerBound].lastIndex(of: open),
                      let finish = data[match.upperBound..<upper].firstIndex(of: close),
                      let row = try? JSONSerialization.jsonObject(with: data[begin...finish]) as? [String: Any],
                      "\(row["RouteID"] ?? "")" == route else { continue }
                let value = row["EstimateTime"]
                if let number = value as? NSNumber { return number.intValue }
                if let text = value as? String, let number = Int(text) { return number }
            }
        }
        return nil
    }
}

// MARK: The trip on the Lock Screen and in the Dynamic Island

struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            RideActivityLockView(state: context.state, attributes: context.attributes)
                .widgetURL(URL(string: "taipeibus://journey"))
        } dynamicIsland: { context in
            let state = context.state
            let language = AppLanguage(rawValue: context.attributes.language) ?? .traditionalChinese
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RouteSignView(sign: state.sign, size: 16).padding(.leading, 4).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RideCountdown(state: state, language: language, size: 24).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.headline).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if let left = state.stopsLeft, let total = state.totalStops, total > 0 {
                            ProgressView(value: Double(max(0, total - left)), total: Double(total)).tint(Color(signHex: state.sign.color))
                        }
                        HStack {
                            Text(state.detail).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer()
                            if let status = state.status, state.target != nil {
                                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }.padding(.horizontal, 4)
                }
            } compactLeading: {
                RouteSignView(sign: state.sign, size: 12)
            } compactTrailing: {
                if state.phase == .riding, let left = state.stopsLeft {
                    Text(AppText.stops(left, language: language)).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                } else if let target = state.target, target > state.updatedAt {
                    Text(timerInterval: state.updatedAt...target, countsDown: true)
                        .font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                        .frame(maxWidth: 52)
                } else {
                    Image(systemName: state.phase == .walking ? "figure.walk" : "bus.fill")
                }
            } minimal: {
                Text(state.sign.text).font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
            }
            .widgetURL(URL(string: "taipeibus://journey"))
            .keylineTint(Color(signHex: state.sign.color))
        }
    }
}
