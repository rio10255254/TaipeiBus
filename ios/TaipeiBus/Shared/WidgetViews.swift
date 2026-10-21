import SwiftUI
import WidgetKit
import TransitCore
#if canImport(ActivityKit)
import ActivityKit
#endif

/// The next arrival at a saved trip's boarding stop, as read from the official feed.
struct CommuteTiming: Hashable, Sendable {
    var arrival: Date?
    /// The official feed's negative codes: not departed, not stopping, last bus gone, no service.
    var status: Int?
}

struct CommuteEntry: TimelineEntry {
    var date: Date
    var language: AppLanguage
    var locked: Bool
    var commutes: [CommuteWidgetPayload.Commute]
    var timings: [String: CommuteTiming]
    var feedFailed = false
    /// When the official times were read. An entry past `staleAfter` shows no countdown, because
    /// the system may not refresh the widget again for a while and an old minute count misleads.
    var fetchedAt: Date? = nil
    static let staleAfter: TimeInterval = 14 * 60
    var stale: Bool { fetchedAt.map { date.timeIntervalSince($0) >= Self.staleAfter } ?? false }
}

struct RouteSignView: View {
    let sign: RouteSign
    var size: CGFloat = 13
    var body: some View {
        Text(sign.text).font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, size * 0.45).padding(.vertical, size * 0.18)
            .frame(minWidth: size * 2.2)
            .foregroundStyle(sign.darkInk ? Color.black : Color.white)
            .background(Color(signHex: sign.color), in: RoundedRectangle(cornerRadius: size * 0.42, style: .continuous))
    }
}

/// Minutes, short status and leave-by advice for one saved trip at one moment.
struct CommuteLine {
    let main: String
    let advice: String?
    let urgent: Bool

    init(_ commute: CommuteWidgetPayload.Commute, timing: CommuteTiming?, at date: Date, language: AppLanguage,
         feedFailed: Bool, stale: Bool = false) {
        guard let ride = commute.ride else {
            if commute.walkOnly == true { main = AppText.text("步行即可", language: language); advice = nil }
            else { main = "—"; advice = AppText.text("開啟 App 規劃一次此行程", language: language) }
            urgent = false; return
        }
        if ride.metro {
            let minutes = ride.headwaySeconds.map { max(1, Int(($0 / 60).rounded())) }
            main = minutes.map { AppText.text("每 %@ 分一班", $0, language: language) } ?? AppText.text("捷運", language: language)
            advice = AppText.text("步行 %@ 分", max(1, Int(ceil(ride.walkSeconds / 60))), language: language)
            urgent = false; return
        }
        if stale {
            main = "—"; advice = AppText.text("點一下更新到站時間", language: language); urgent = false; return
        }
        if let status = timing?.status, status < 0 {
            main = AppText.format(Self.statusKey(status), values: [], language: language)
            advice = nil; urgent = false; return
        }
        guard let arrival = timing?.arrival else {
            main = AppText.text("暫無預估", language: language)
            advice = feedFailed ? AppText.text("到站資料暫時無法取得", language: language) : nil
            urgent = false; return
        }
        let seconds = arrival.timeIntervalSince(date)
        // The feed only times the next bus. Once it is due, say so instead of a frozen "arriving".
        if seconds < -90 {
            main = "—"; advice = AppText.text("下一班時間更新中", language: language); urgent = false; return
        }
        main = seconds <= 60 ? AppText.text("即將進站", language: language) : AppText.text("%@ 分", Int(ceil(seconds / 60)), language: language)
        let leave = seconds - ride.walkSeconds
        if leave >= 60 { advice = AppText.text("%@ 分後出門", Int(leave / 60), language: language); urgent = false }
        else if leave >= -30 { advice = AppText.text("現在出門", language: language); urgent = true }
        else { advice = AppText.text("這班可能趕不上", language: language); urgent = true }
    }
    static func statusKey(_ status: Int) -> String {
        [-1: "尚未發車", -2: "交管不停靠", -3: "末班已過", -4: "今日未營運"][status] ?? "暫無預估"
    }
}

struct CommuteWidgetView: View {
    let entry: CommuteEntry
    let family: WidgetFamily

    var body: some View {
        if entry.locked { locked }
        else if entry.commutes.isEmpty { empty }
        else {
            switch family {
            case .accessoryRectangular: rectangular(entry.commutes[0])
            case .accessoryInline: inline(entry.commutes[0])
            case .systemMedium: medium
            default: small(entry.commutes[0])
            }
        }
    }

    private var language: AppLanguage { entry.language }
    private func line(_ commute: CommuteWidgetPayload.Commute) -> CommuteLine {
        CommuteLine(commute, timing: entry.timings[commute.id], at: entry.date, language: language,
                    feedFailed: entry.feedFailed, stale: entry.stale)
    }

    private var locked: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(AppText.text("常用行程", language: language), systemImage: "sparkles").font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(AppText.text("用 Pro 在桌面看常用行程的下一班車", language: language))
                .font(.subheadline.weight(.semibold)).lineLimit(3).minimumScaleFactor(0.8)
            Text(AppText.text("升級 Pro", language: language)).font(.caption.weight(.bold)).foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "taipeibus://pro"))
    }
    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(AppText.text("常用行程", language: language), systemImage: "star.fill").font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(AppText.text("在台北公車儲存常用行程，這裡就會顯示下一班車", language: language))
                .font(.subheadline.weight(.medium)).lineLimit(4).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func header(_ commute: CommuteWidgetPayload.Commute) -> some View {
        Label(commute.title, systemImage: commute.symbol).font(.caption.weight(.semibold)).lineLimit(1)
            .foregroundStyle(.secondary)
    }
    private func small(_ commute: CommuteWidgetPayload.Commute) -> some View {
        let value = line(commute)
        return VStack(alignment: .leading, spacing: 4) {
            header(commute)
            if let ride = commute.ride {
                HStack(spacing: 5) {
                    RouteSignView(sign: ride.sign, size: 13)
                    Text(ride.toward).font(.caption2.weight(.medium)).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(value.main).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5).contentTransition(.numericText())
            if let ride = commute.ride {
                Text(ride.stopName).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
            }
            if let advice = value.advice {
                Text(advice).font(.caption2.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(value.urgent ? Color.orange : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "taipeibus://commute/\(commute.id)"))
    }
    private var medium: some View {
        VStack(spacing: 8) {
            ForEach(Array(entry.commutes.prefix(2).enumerated()), id: \.element.id) { index, commute in
                if index > 0 { Divider() }
                Link(destination: URL(string: "taipeibus://commute/\(commute.id)")!) { row(commute) }.foregroundStyle(Color.primary)
            }
            if entry.commutes.count == 1 { Spacer(minLength: 0) }
        }
    }
    private func row(_ commute: CommuteWidgetPayload.Commute) -> some View {
        let value = line(commute)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: commute.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.tint)
                .frame(width: 30, height: 30).background(.tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(commute.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let ride = commute.ride { RouteSignView(sign: ride.sign, size: 11) }
                }
                Text(commute.ride.map { $0.stopName + " · " + $0.toward } ?? AppText.text("開啟 App 規劃一次此行程", language: language))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value.main).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let advice = value.advice {
                    Text(advice).font(.caption2.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(value.urgent ? Color.orange : Color.secondary)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
    private func rectangular(_ commute: CommuteWidgetPayload.Commute) -> some View {
        let value = line(commute)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: commute.symbol)
                Text(commute.title).lineLimit(1)
                if let ride = commute.ride { Text(ride.sign.text).fontWeight(.bold) }
            }.font(.caption.weight(.semibold))
            Text(value.main).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit().lineLimit(1)
            if let advice = value.advice { Text(advice).font(.caption2).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "taipeibus://commute/\(commute.id)"))
    }
    private func inline(_ commute: CommuteWidgetPayload.Commute) -> some View {
        let value = line(commute)
        return Text((commute.ride.map { $0.sign.text + " " } ?? "") + value.main)
    }
}

#if canImport(ActivityKit)
/// All island sizes use these same components, including the in-app layout checks.
struct RideActivityBadge: View {
    let state: RideActivityAttributes.ContentState
    var body: some View {
        if [.walking, .cycling, .transferring].contains(state.phase) {
            Image(systemName: state.phase == .cycling ? "bicycle" : "figure.walk")
                .font(.system(size: 24, weight: .semibold)).frame(width: 36, height: 30)
        } else { RouteSignView(sign: state.sign, size: 14).frame(maxWidth: 108, alignment: .leading) }
    }
}

struct RideIslandLeading: View {
    let presentation: RideActivityPresentation
    var body: some View {
        Group {
            if [.walking, .cycling, .transferring].contains(presentation.state.phase) {
                Image(systemName: presentation.symbol).font(.system(size: 16, weight: .semibold))
            } else if presentation.state.sign.text.count > 5 {
                Image(systemName: presentation.symbol).font(.system(size: 16, weight: .semibold))
            } else {
                RouteSignView(sign: presentation.state.sign, size: 12)
            }
        }
        .frame(maxWidth: 56).foregroundStyle(.white)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

struct RideIslandTrailing: View {
    let presentation: RideActivityPresentation
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let target = presentation.target {
                Text(timerInterval: presentation.state.updatedAt...target, countsDown: true, showsHours: false)
                    .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                    .multilineTextAlignment(.trailing)
            } else if let text = presentation.compactText {
                Text(text).font(.system(size: 13, weight: .bold, design: .rounded)).lineLimit(1)
            } else {
                Image(systemName: presentation.symbol).font(.system(size: 15, weight: .semibold))
            }
            if let secondary = presentation.secondaryMetric {
                Text(secondary).font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: 58)
        .foregroundStyle(presentation.alightingSoon ? Color.orange : Color.white)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

struct RideIslandMinimal: View {
    let presentation: RideActivityPresentation
    var body: some View {
        // No long route names squeezed into the detached circle. Identify the current action
        // and show a count only while it is fresh; the expanded view retains the full route.
        VStack(spacing: 0) {
            Image(systemName: presentation.symbol)
                .font(.system(size: presentation.target == nil || presentation.alightingSoon ? 16 : 9, weight: .semibold))
            if let target = presentation.target, !presentation.alightingSoon {
                Text(timerInterval: presentation.state.updatedAt...target, countsDown: true, showsHours: false)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).multilineTextAlignment(.center)
            }
        }
        .frame(width: 24, height: 26)
        .foregroundStyle(presentation.alightingSoon ? Color.orange : Color.white)
        .accessibilityElement(children: .ignore).accessibilityLabel(presentation.accessibilityLabel)
    }

}

struct RideCountdown: View {
    let state: RideActivityAttributes.ContentState
    let language: AppLanguage
    var size: CGFloat = 28
    var stale = false
    var showsCaption = false
    var body: some View {
        let value = RideActivityPresentation(state: state, language: language, systemStale: stale)
        VStack(alignment: .trailing, spacing: 1) {
        if let target = value.target {
            Text(timerInterval: state.updatedAt...target, countsDown: true, showsHours: false)
                .font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            Text(value.status).font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.trailing)
        }
        if showsCaption, value.target != nil {
            Text(value.metricCaption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        }
    }
}

struct RideActivityDetails: View {
    let presentation: RideActivityPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(presentation.state.headline).font(.headline).lineLimit(2).minimumScaleFactor(0.85)
            if let progress = presentation.progress {
                HStack(spacing: 10) {
                    Text(AppText.remainingStops(max(0, presentation.state.stopsLeft ?? 0), language: presentation.language))
                        .font(.subheadline.weight(.semibold)).fixedSize(horizontal: true, vertical: false)
                    ProgressView(value: progress)
                        .tint(presentation.alightingSoon ? .orange : Color(signHex: presentation.state.sign.color))
                }
            } else if let distance = presentation.secondaryMetric {
                Text(distance).font(.subheadline.weight(.semibold))
            }
            if presentation.stale {
                Text(presentation.status).font(.subheadline).foregroundStyle(.secondary)
            } else {
                if presentation.state.stopsLeft == nil {
                    Text(presentation.state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let next = presentation.state.nextInstruction {
                    Text(next).font(.caption).lineLimit(2)
                }
                if let source = presentation.state.status, presentation.state.target != nil, source != presentation.state.detail {
                    Text(source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RideActivityLockView: View {
    let state: RideActivityAttributes.ContentState
    let attributes: RideActivityAttributes
    var stale = false
    private var language: AppLanguage { AppLanguage(rawValue: attributes.language) ?? .traditionalChinese }
    var body: some View {
        let value = RideActivityPresentation(state: state, language: language, systemStale: stale)
        Group {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if [.walking, .cycling, .transferring].contains(state.phase) {
                        Image(systemName: value.symbol).font(.title2).frame(width: 36)
                    } else { RouteSignView(sign: state.sign, size: 15).frame(maxWidth: 108) }
                    Text(value.alightingSoon ? AppText.text("準備下車", language: language) : value.phaseTitle)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    RideCountdown(state: state, language: language, size: 24, stale: stale, showsCaption: true)
                        .frame(maxWidth: 130, alignment: .trailing)
                }
                RideActivityDetails(presentation: value)
            }
            .padding(16)
        }
    }
}
#endif
