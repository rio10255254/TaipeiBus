import SwiftUI
import StoreKit
import TransitCore

struct ProPurchaseView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var purchases: ProPurchases
    @Environment(\.dismiss) private var dismiss
    /// The annual plan is the better value, so it is shown selected unless another plan is active.
    @State private var selected: ProPlan = .yearly
    /// Whole-percent saving of the annual plan over twelve monthly payments, from Apple's prices.
    private var yearlySaving: Int? {
        guard let month = purchases.products[ProPlan.monthly.productID]?.price,
              let year = purchases.products[ProPlan.yearly.productID]?.price else { return nil }
        let full = NSDecimalNumber(decimal: month * 12).doubleValue, annual = NSDecimalNumber(decimal: year).doubleValue
        guard full > 0, annual < full else { return nil }
        let percent = Int(((1 - annual / full) * 100).rounded(.down))
        return percent >= 5 ? percent : nil
    }
    private let privacy = URL(string:"https://rio10255254.github.io/TaipeiBus/privacy.html")!
    private let terms = URL(string:"https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    HStack(alignment:.center,spacing:12) {
                        Image("BrandMark").resizable().scaledToFit().frame(width:56,height:56)
                            .clipShape(RoundedRectangle(cornerRadius:12.5,style:.continuous)).accessibilityHidden(true)
                        VStack(alignment:.leading,spacing:2) {
                            Text(AppText.text("一路 Pro")).font(.title.bold())
                            Text(AppText.text("讓每天的通勤更順手。")).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    // Everything Pro adds at a glance; the details follow below the purchase button.
                    LazyVGrid(columns:[GridItem(.flexible(),spacing:8),GridItem(.flexible(),spacing:8)],alignment:.leading,spacing:8) {
                        ForEach(Self.benefits,id:\.title) { item in
                            Label { Text(AppText.text(item.title)).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8) }
                                icon: { SettingsIcon(symbol:item.symbol,color:item.color) }
                                .frame(maxWidth:.infinity,minHeight:40,alignment:.leading).padding(.horizontal,12)
                                .background(Color(uiColor:.secondarySystemGroupedBackground),in:live.shape(.row))
                        }
                    }.accessibilityIdentifier("pro-benefit-grid")
                    if purchases.hasPro {
                        Label(AppText.text(purchases.isInTrial ? "正在免費試用 Pro" : "Pro 已開通"),systemImage:"checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                        if let date = purchases.periodEndsAt {
                            Text(AppText.text(purchases.willAutoRenew == false ? "可使用至 %@" : purchases.isInTrial ? "試用至 %@" : purchases.willAutoRenew == true ? "續訂日期 %@" : "本期至 %@",
                                date.formatted(.dateTime.year().month(.abbreviated).day().locale(AppLanguage.current.locale))))
                                .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("pro-period-end")
                        }
                    }
                    VStack(spacing:10) {
                        ForEach(ProPlan.allCases) { plan in
                            Button { selected = plan } label: {
                                HStack(spacing:12) {
                                    Image(systemName:selected == plan ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected == plan ? Brand.accent : Color.secondary)
                                    Text(plan.title).fontWeight(.semibold)
                                    if plan == .yearly, let saving = yearlySaving {
                                        Text(AppText.text("省 %@%%", saving)).font(.caption.weight(.bold)).foregroundStyle(.white)
                                            .padding(.horizontal, 7).padding(.vertical, 3).background(Color.green, in: Capsule())
                                            .accessibilityIdentifier("pro-yearly-saving")
                                    }
                                    Spacer()
                                    if let product = purchases.products[plan.productID] {
                                        VStack(alignment:.trailing,spacing:3) {
                                            Text(product.displayPrice).font(.title3.bold())
                                            if plan == .yearly {
                                                Text(plan.period + " · " + AppText.text("約 %@／月", (product.price / 12).formatted(product.priceFormatStyle)))
                                                    .font(.caption).foregroundStyle(.secondary)
                                            } else { Text(plan.period).font(.caption).foregroundStyle(.secondary) }
                                            if purchases.offersSevenDayTrial(plan) {
                                                Text(AppText.text("先免費試用 7 天")).font(.caption).foregroundStyle(Brand.accent)
                                            }
                                        }
                                    } else { Text(AppText.text("準備中")).foregroundStyle(.secondary) }
                                }.padding(16).frame(maxWidth:.infinity,minHeight:70)
                                    .background(Color(uiColor:.secondarySystemGroupedBackground),in:live.shape(.panel))
                                    .overlay { live.shape(.panel).stroke(selected == plan ? Brand.accent : Color.clear,lineWidth:1.5) }
                            }.buttonStyle(PhonePressStyle()).foregroundStyle(.primary)
                                .accessibilityIdentifier("pro-plan-"+plan.rawValue)
                        }
                    }
                    Button { Task { await purchases.purchase(selected) } } label: {
                        Group {
                            if purchases.busy { ProgressView().tint(.white) }
                            else if purchases.hasPro && purchases.activePlan == selected { Text(AppText.text("目前使用此方案")) }
                            else if purchases.offersSevenDayTrial(selected) { Text(AppText.text("免費試用 7 天")) }
                            else if let product = purchases.products[selected.productID] {
                                Text(AppText.text("訂閱 · %@／%@",product.displayPrice,selected.unit))
                            } else { Text(AppText.text("購買選項準備中")) }
                        }.font(.headline).frame(maxWidth:.infinity,minHeight:54)
                    }.buttonStyle(MapActionStyle(prominent:true))
                        .disabled(purchases.busy || purchases.loadingProducts || purchases.products[selected.productID] == nil ||
                                  purchases.hasPro && purchases.activePlan == selected)
                        .accessibilityIdentifier("pro-purchase")
                    if purchases.offersSevenDayTrial(selected), let product = purchases.products[selected.productID] {
                        Text(AppText.text("7 天免費，之後%@ %@。試用結束前至少 24 小時取消，就不會收費。",selected.period,product.displayPrice))
                            .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("pro-trial-terms")
                    }
                    if purchases.products.isEmpty && !purchases.loadingProducts {
                        Button(AppText.text("重新載入購買選項")) { Task { await purchases.loadProducts() } }
                            .frame(minHeight:44).accessibilityIdentifier("pro-reload-products")
                    }
                    if let message = purchases.message { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("pro-purchase-message") }
                    Text(AppText.text("免費版每天可試用 3 次即時列車或跟隨鏡頭；路線規劃、導航、官方到站與 3D 車輛仍可免費使用。"))
                        .font(.footnote).foregroundStyle(.secondary)
                    VStack(alignment:.leading,spacing:16) {
                        ForEach(Self.benefits,id:\.title) { item in benefit(item.symbol,color:item.color,title:item.title,detail:item.detail) }
                    }.padding(.top,4)
                    HStack(spacing:20) {
                        Button(AppText.text("恢復購買")) { Task { await purchases.restore() } }
                            .accessibilityIdentifier("pro-restore")
                        Button(AppText.text("管理訂閱")) { Task { await purchases.manage() } }
                            .accessibilityIdentifier("pro-manage")
                    }.font(.subheadline).frame(minHeight:44).disabled(purchases.busy)
                    Text(AppText.text("兩種方案提供相同功能。七天試用限符合 Apple 資格的帳號使用一次，之後依所選方案自動續訂。付款與取消由 Apple 處理，確認畫面會顯示價格和續訂日期。"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing:20) {
                        Link(AppText.text("隱私政策"),destination:privacy)
                        Link(AppText.text("使用條款"),destination:terms)
                    }.font(.caption).frame(minHeight:36)
                }.padding(22)
            }.background(Color(uiColor:.systemGroupedBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) {
                    Button(AppText.text("完成")) { dismiss() }.accessibilityIdentifier("pro-close")
                } }
        }.task {
            await purchases.refreshAccess(); await purchases.loadProducts()
            if let active = purchases.activePlan { selected = active }
        }
    }
    private static let benefits: [(symbol: String, color: Color, title: String, detail: String)] = [
        ("tram.fill",Color.indigo,"即時捷運列車","全路網列車在地圖上即時移動，高架與地下分層顯示，點一下就能跟隨。"),
        ("scope",Brand.accent,"跟隨鏡頭","鏡頭跟在公車或列車後方，隨路線轉向，停靠時繞著車站。"),
        ("bell.badge.fill",Color.red,"下車提醒","快到下車站前通知並震動，手機放口袋也不會坐過站。"),
        ("timer",Color.teal,"動態島與鎖定畫面","不用打開 App，就能看到等車倒數與還有幾站下車。"),
        ("square.grid.2x2.fill",Color.blue,"桌面小工具","常用行程的下一班車與建議出門時間，直接顯示在主畫面。"),
        ("house.fill",Color.green,"常用行程捷徑","把回家、上班與常去的地方存好，一點就能預覽路線。"),
        ("slider.horizontal.3",Color.purple,"個人路線偏好","選擇時間優先、少走路或少轉乘，依照你的習慣比較路線。"),
        ("sparkles",Color.pink,"更聰明的一句話規劃","用更大的線上模型讀懂你說的行程，複雜的說法也更準，每天可用次數也更多。"),
    ]
    private func benefit(_ symbol: String,color: Color,title: String,detail: String) -> some View {
        HStack(alignment:.top,spacing:14) {
            SettingsIcon(symbol:symbol,color:color)
            VStack(alignment:.leading,spacing:5) {
                Text(AppText.text(title)).font(.headline)
                Text(AppText.text(detail)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
}

struct ProSettingsView: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject private var purchases: ProPurchases
    @ObservedObject private var commutes: CommuteLibrary
    @State private var showingPurchase = false
    init(model: TransitAppModel) { self.model = model; purchases = model.purchases; commutes = model.commutes }
    var body: some View {
        List {
            Section {
                Button { showingPurchase = true } label: {
                    HStack {
                        SettingsLabel(title: AppText.text(purchases.hasPro ? "Pro 已開通" : "查看 Pro 方案"), symbol: "star.fill", color: Brand.accent)
                        Spacer(); Image(systemName:"chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }.accessibilityIdentifier("pro-open-plans")
                if purchases.hasPro {
                    Button { Task { await purchases.manage() } } label: {
                        SettingsLabel(title: AppText.text("管理訂閱"), symbol: "creditcard.fill", color: .green)
                    }
                }
            } footer: { Text(AppText.text("免費版每天可試用 3 次即時列車或跟隨鏡頭；路線規劃、導航、官方到站與 3D 車輛仍可免費使用。")) }
            Section {
                NavigationLink { SavedJourneysView(model:model) } label: {
                    SettingsLabel(title: AppText.text("常用行程"), symbol: "house.fill", color: .green)
                }.accessibilityIdentifier("pro-saved-journeys")
                if purchases.hasPro {
                    Picker(selection:$commutes.preference) {
                        ForEach(RoutePreference.allCases) { choice in Text(choice.title).tag(choice) }
                    } label: {
                        SettingsLabel(title: AppText.text("預設路線偏好"), symbol: "slider.horizontal.3", color: .purple)
                    }.accessibilityIdentifier("pro-default-preference")
                } else {
                    Button { showingPurchase = true } label: {
                        SettingsLabel(title: AppText.text("個人路線偏好"), symbol: "slider.horizontal.3", color: .purple)
                    }
                }
            } header: { Text(AppText.text("通勤")) }
            if model.planner.started { Text(AppText.text("新偏好會用於下一次規劃。")) .font(.footnote).foregroundStyle(.secondary) }
            if purchases.hasPro {
                Section {
                    Toggle(isOn: $model.rideActivityOn) {
                        SettingsLabel(title: AppText.text("動態島與鎖定畫面"), symbol: "timer", color: .teal)
                    }.accessibilityIdentifier("pro-ride-activity")
                    HStack {
                        Text(model.liveActivityStatus).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("pro-live-activity-readiness")
                        Spacer()
                        if model.liveActivityState == .needsPermission {
                            Button(AppText.text("開啟設定")) { model.openAppSettings() }
                        } else if model.liveActivityState == .unavailable {
                            Button(AppText.text("重新顯示")) { model.retryLiveActivity() }
                        }
                    }
                    Toggle(isOn: Binding(get: { model.alightReminderOn }, set: { model.setAlightReminderPreference($0) })) {
                        SettingsLabel(title: AppText.text("下車提醒"), symbol: "bell.badge.fill", color: .red)
                    }.accessibilityIdentifier("pro-alight-reminder")
                    HStack {
                        Text(model.alightReminderStatus).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("pro-alight-readiness")
                        Spacer()
                        if model.alightReminderState == .needsPermission {
                            Button(AppText.text(model.alightReminder.permission == .denied ? "開啟設定" : "允許通知")) {
                                model.requestAlightReminderAccess()
                            }.accessibilityIdentifier("pro-authorize-notifications")
                        }
                    }
                } header: { Text(AppText.text("導航")) } footer: {
                    Text(AppText.text("導航期間在背景更新，結束後停止。小工具可從主畫面新增。"))
                }
            }
            Section {
                Button { Task { await purchases.restore() } } label: {
                    SettingsLabel(title: AppText.text("恢復購買"), symbol: "arrow.clockwise", color: .gray)
                }
                if let message = purchases.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }.navigationTitle(AppText.text("一路 Pro")).navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented:$showingPurchase) { ProPurchaseView(purchases:purchases) }
            .task { await purchases.refreshAccess(); await model.refreshNavigationPermissions() }
    }
}

struct SavedJourneysView: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject private var purchases: ProPurchases
    @ObservedObject private var library: CommuteLibrary
    @State private var showingPurchase = false
    init(model: TransitAppModel) { self.model = model; purchases = model.purchases; library = model.commutes }
    var body: some View {
        List {
            if library.journeys.isEmpty {
                Text(AppText.text("規劃路線後，在選單選擇「儲存行程」。")) .foregroundStyle(.secondary)
            }
            ForEach(library.journeys) { saved in
                // Tapping a saved trip previews its route, with or without an active subscription.
                Button { model.previewSavedJourney(saved); model.showSavedJourneyRequested = true } label: {
                    VStack(alignment:.leading,spacing:5) {
                        Label(saved.title,systemImage:saved.symbol).font(.headline)
                        Text((saved.origin?.localizedName ?? AppText.text("目前位置"))+" → "+saved.destination.localizedName)
                            .font(.subheadline).foregroundStyle(.secondary)
                        if purchases.hasPro { Text(saved.preference.title).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical,4).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("saved-journey-"+saved.id.uuidString)
            }.onDelete { indices in library.remove(Set(indices.map { library.journeys[$0].id })) }
                .onMove { library.move(from:$0,to:$1) }
            if !purchases.hasPro {
                Button(AppText.text("查看 Pro 方案")) { showingPurchase = true }
                Text(AppText.text("已儲存的行程會保留在手機，訂閱到期後仍可一點開啟；新增行程與路線偏好需要 Pro。")) .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle(AppText.text("常用行程"))
            .toolbar { EditButton() }
            .sheet(isPresented:$showingPurchase) { ProPurchaseView(purchases:purchases) }
    }
}

struct SaveJourneyView: View {
    @ObservedObject var model: TransitAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var symbol = "house.fill"
    @State private var preference: RoutePreference = .balanced
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField(AppText.text("行程名稱"),text:$title).accessibilityIdentifier("commute-title")
                Picker(AppText.text("圖示"),selection:$symbol) {
                    ForEach(SavedJourney.symbols,id:\.self) { image in Image(systemName:image).tag(image) }
                }
                Picker(AppText.text("路線偏好"),selection:$preference) {
                    ForEach(RoutePreference.allCases) { choice in Text(choice.title).tag(choice) }
                }
                if let destination = model.planner.destination {
                    Text((model.planner.usingLocation ? AppText.text("目前位置") : model.planner.origin?.localizedName ?? AppText.text("出發地"))+" → "+destination.localizedName)
                        .foregroundStyle(.secondary)
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }.navigationTitle(AppText.text("儲存行程")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button(AppText.text("取消")) { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) {
                        Button(AppText.text("儲存")) {
                            guard model.purchases.hasPro, let destination = model.planner.destination else { return }
                            if model.commutes.store(title:title,symbol:symbol,
                                origin:model.planner.usingLocation ? nil : model.planner.origin,destination:destination,preference:preference) { dismiss() }
                            else { message = AppText.text("請輸入行程名稱；最多可儲存 50 個行程。") }
                        }.disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("commute-save")
                    }
                }
        }.onAppear { title = model.planner.destination?.localizedName ?? ""; preference = model.tripPreference ?? model.commutes.preference }
    }
}

struct TripPreferenceView: View {
    @ObservedObject var model: TransitAppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(RoutePreference.allCases) { choice in
                Button { model.setTripPreference(choice); dismiss() } label: {
                    HStack { Text(choice.title); Spacer(); if choice == (model.tripPreference ?? model.commutes.preference) { Image(systemName:"checkmark") } }
                }.accessibilityIdentifier("trip-preference-"+choice.rawValue)
            }.navigationTitle(AppText.text("路線偏好")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button(AppText.text("取消")) { dismiss() } } }
        }
    }
}

/// Live metro trains for a free user: a 15-minute look from today's trials, or the way to Pro.
struct LiveTrainsChip: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let minutesLeft = model.liveTrainsUntil.map { Int(ceil(max(0, $0.timeIntervalSince(timeline.date)) / 60)) } ?? 0
            let active = minutesLeft > 0
            let trials = model.freeTrialsLeft
            Button {
                if !active && trials > 0 { model.startLiveTrainTrial() } else if !active { model.showingProPlans = true }
            } label: {
                Label(active ? AppText.text("即時列車 · 剩 %@ 分", minutesLeft)
                             : trials > 0 ? AppText.text("顯示即時列車 · 今日剩 %@ 次", trials) : AppText.text("即時列車 · Pro"),
                      systemImage: "tram.fill")
                    .liveFont(.subheadline, weight: .semibold).monospacedDigit()
                    .padding(.horizontal, 14 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 40)
                    .phoneGlass(in: Capsule())
            }.buttonStyle(PhonePressStyle()).foregroundStyle(active ? Color.secondary : Color.primary)
                .disabled(active)
                .accessibilityIdentifier("live-trains-trial")
        }
    }
}

/// A brief note after a trial is used or when today's trials are gone. It disappears on its own.
struct ProNoteBanner: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    var body: some View {
        if let note = model.proNote {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Brand.accent)
                Text(note).liveFont(.subheadline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(AppText.text("了解 Pro")) { model.proNote = nil; model.showingProPlans = true }
                    .liveFont(.subheadline, weight: .semibold).accessibilityIdentifier("pro-note-open")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .phoneGlass(in: live.shape(.panel))
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: note) {
                try? await Task.sleep(for: .seconds(5))
                if model.proNote == note { withAnimation(.smooth) { model.proNote = nil } }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("pro-note")
        }
    }
}
