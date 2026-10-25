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
    @Environment(\.widgetRenderingMode) private var renderingMode
    let sign: RouteSign
    var size: CGFloat = 13
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
        let label = Text(sign.text).font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, size * 0.45).padding(.vertical, size * 0.18)
            .frame(minWidth: size * 2.2)
        if renderingMode == .fullColor {
            label.foregroundStyle(sign.darkInk ? Color.black : Color.white)
                .background(Color(signHex: sign.color), in: shape)
        } else {
            // Tinted and clear Home Screens draw everything in one tint, so a filled sign would
            // swallow its own number; an outlined sign in the accent keeps it readable.
            label.foregroundStyle(.primary)
                .background(shape.fill(.primary.opacity(0.12)))
                .overlay(shape.strokeBorder(.primary.opacity(0.55), lineWidth: 1))
                .widgetAccentable()
        }
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
    @Environment(\.widgetRenderingMode) private var renderingMode
    /// False in StandBy and other places that drop the widget background and show it from
    /// across the room: the figure grows and the small print goes.
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    let entry: CommuteEntry
    let family: WidgetFamily
    private func adviceColor(_ urgent: Bool) -> Color {
        urgent && renderingMode == .fullColor ? Color.orange : Color.secondary
    }

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
            Text(value.main).font(.system(size: showsBackground ? 30 : 40, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5).contentTransition(.numericText())
                .widgetAccentable()
            if let ride = commute.ride, showsBackground {
                Text(ride.stopName).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
            }
            if let advice = value.advice {
                Text(advice).font((showsBackground ? Font.caption2 : Font.footnote).weight(.semibold)).lineLimit(1)
                    .foregroundStyle(adviceColor(value.urgent))
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
                .widgetAccentable()
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
                    .widgetAccentable()
                if let advice = value.advice {
                    Text(advice).font(.caption2.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(adviceColor(value.urgent))
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

/// Route colours are chosen for light map signs; very dark ones disappear on the black island.
func rideIslandTint(_ presentation: RideActivityPresentation) -> Color {
    if presentation.alightingSoon { return .orange }
    let value = UInt32(presentation.state.sign.color.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x1F6FD1
    let luminance = 0.2126 * Double((value >> 16) & 0xFF) + 0.7152 * Double((value >> 8) & 0xFF) + 0.0722 * Double(value & 0xFF)
    return luminance < 70 ? .white : Color(signHex: presentation.state.sign.color)
}

/// The final ten minutes drain the ring. Further away it stays full, so a fresh trip does not
/// look nearly finished.
let rideRingWindow: TimeInterval = 600

/// Share of the ten-minute window left at the latest update; full when alighting is due.
func rideRingRemaining(_ presentation: RideActivityPresentation) -> Double? {
    if presentation.alightingSoon { return 1 }
    return presentation.target.map { min(1, max(0, $0.timeIntervalSince(presentation.now) / rideRingWindow)) }
}

/// A countdown ring on a halo in the route colour. Live Activities cannot animate on their own,
/// and the system-timed ProgressView delayed island rendering whenever two activities were
/// shown, so the ring is plain shapes advanced by each update while the time inside keeps
/// counting on its own.
struct RideGlowRing: View {
    let presentation: RideActivityPresentation
    var lineWidth: CGFloat = 4
    /// The detached circle has no room around it for the halo.
    var halo = true
    var body: some View {
        let tint = rideIslandTint(presentation)
        let remaining = rideRingRemaining(presentation)
        let glowing = halo && remaining != nil
        ZStack {
            Circle().stroke(glowing ? tint.opacity(0.22) : Color.primary.opacity(0.14),
                            lineWidth: lineWidth * (glowing ? 2.6 : 1))
            if let remaining {
                Circle().trim(from: 0, to: remaining)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

struct RideIslandMinimal: View {
    let presentation: RideActivityPresentation
    var body: some View {
        // The detached circle has no room for a clock ("14:05" became "14:…"), but it still
        // carries the key figure: stops left on board, metres while walking, otherwise minutes.
        ZStack {
            RideGlowRing(presentation: presentation, lineWidth: 2.5, halo: false)
            if presentation.alightingSoon || presentation.stale {
                Image(systemName: presentation.symbol).font(.system(size: 12, weight: .bold))
                    .foregroundStyle(presentation.alightingSoon ? Color.orange : Color.white)
            } else if let figure = presentation.minimalFigure {
                VStack(spacing: -1) {
                    Text(figure.value).font(.system(size: figure.value.count > 2 ? 9 : 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(figure.unit).font(.system(size: 6.5, weight: .semibold))
                }
                .lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(.white)
            } else {
                Image(systemName: presentation.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityElement(children: .ignore).accessibilityLabel(presentation.accessibilityLabel)
    }
}

/// The time inside its ring, with what it counts down to. Without a usable time the ring stays
/// empty and the status ("留意來車", "點一下更新") takes the time's place.
struct RideCountdownRing: View {
    let presentation: RideActivityPresentation
    var diameter: CGFloat = 64
    /// The expanded island names the countdown in its title, keeping the region short.
    var showsCaption = true
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RideGlowRing(presentation: presentation, lineWidth: diameter / 14)
                if let target = presentation.target {
                    Text(timerInterval: presentation.state.updatedAt...target, countsDown: true, showsHours: false)
                        .font(.system(size: diameter * 0.25, weight: .bold, design: .rounded)).monospacedDigit()
                        .multilineTextAlignment(.center).minimumScaleFactor(0.8)
                        .frame(width: diameter * 0.78)
                } else {
                    Image(systemName: presentation.symbol).font(.system(size: diameter * 0.28, weight: .semibold))
                        .foregroundStyle(presentation.alightingSoon ? Color.orange : Color.primary)
                }
            }
            .frame(width: diameter, height: diameter)
            // A stale status is already in the details beside the ring.
            if showsCaption, presentation.target != nil || !presentation.stale {
                Text(presentation.target != nil ? presentation.metricCaption : presentation.status)
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: diameter + 36)
            }
        }
    }
}

struct RideActivityDetails: View {
    let presentation: RideActivityPresentation
    /// The expanded island has a fixed height limit; keep one line each and omit the source.
    var compact = false
    var body: some View {
        let state = presentation.state
        VStack(alignment: .leading, spacing: 4) {
            Text(state.headline).font(.headline).lineLimit(compact ? 1 : 2).minimumScaleFactor(0.85)
            if presentation.stale {
                Text(presentation.status).font(.subheadline).foregroundStyle(.secondary)
            } else {
                if let left = state.stopsLeft {
                    Text(AppText.remainingStops(max(0, left), language: presentation.language))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(presentation.alightingSoon ? Color.orange : Color.primary)
                } else if let distance = presentation.secondaryMetric {
                    HStack(spacing: 6) {
                        Text(distance).font(.subheadline.weight(.semibold))
                        Text(state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text(state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let next = state.nextInstruction {
                    Text(next).font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
                }
                // Say when a time is an estimate, e.g. "班距推估" for a metro headway.
                if !compact, let source = state.status, state.target != nil, source != state.detail {
                    Text(source).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    RideActivityBadge(state: state)
                    Text(value.alightingSoon ? AppText.text("準備下車", language: language) : value.phaseTitle)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                RideActivityDetails(presentation: value)
            }
            RideCountdownRing(presentation: value, diameter: 66)
        }
        .padding(16)
    }
}
#endif
