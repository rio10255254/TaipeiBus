import SwiftUI
import StoreKit
import TransitCore

struct ProPurchaseView: View {
    @ObservedObject var purchases: ProPurchases
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ProPlan = .monthly
    private let privacy = URL(string:"https://rio10255254.github.io/TaipeiBus/privacy.html")!
    private let terms = URL(string:"https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    VStack(alignment:.leading,spacing:8) {
                        Image(systemName:"tram.fill").font(.system(size:34)).foregroundStyle(.blue)
                        Text(AppText.text("台北公車 Pro")).font(.largeTitle.bold())
                        Text(AppText.text("讓每天的通勤更順手。")) .foregroundStyle(.secondary)
                    }
                    benefit("house.fill",title:"常用行程捷徑",detail:"把回家、上班與常去的地方存好，一點就能預覽路線。")
                    benefit("slider.horizontal.3",title:"個人路線偏好",detail:"選擇時間優先、少走路或少轉乘，依照你的習慣比較路線。")
                    Text(AppText.text("基本導航、官方到站與 3D 追車仍可免費使用。"))
                        .font(.footnote).foregroundStyle(.secondary)
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
                                        .foregroundStyle(selected == plan ? Color.blue : Color.secondary)
                                    Text(plan.title).fontWeight(.semibold)
                                    Spacer()
                                    if let product = purchases.products[plan.productID] {
                                        VStack(alignment:.trailing,spacing:3) {
                                            Text(product.displayPrice).font(.title3.bold())
                                            Text(plan.period).font(.caption).foregroundStyle(.secondary)
                                            if purchases.offersSevenDayTrial(plan) {
                                                Text(AppText.text("先免費試用 7 天")).font(.caption).foregroundStyle(.blue)
                                            }
                                        }
                                    } else { Text(AppText.text("準備中")).foregroundStyle(.secondary) }
                                }.padding(16).frame(maxWidth:.infinity,minHeight:70)
                                    .background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:18))
                                    .overlay { RoundedRectangle(cornerRadius:18).stroke(selected == plan ? Color.blue : Color.clear,lineWidth:1.5) }
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
                                Text(AppText.text("訂閱 %@ · %@",selected.period,product.displayPrice))
                            } else { Text(AppText.text("購買選項準備中")) }
                        }.font(.headline).frame(maxWidth:.infinity,minHeight:54)
                    }.buttonStyle(MapActionStyle(prominent:true))
                        .disabled(purchases.busy || purchases.loadingProducts || purchases.products[selected.productID] == nil ||
                                  purchases.hasPro && purchases.activePlan == selected)
                        .accessibilityIdentifier("pro-purchase")
                    if purchases.offersSevenDayTrial(selected), let product = purchases.products[selected.productID] {
                        Text(AppText.text("7 天免費，之後 %@ %@。試用結束前至少 24 小時取消，就不會收費。",selected.period,product.displayPrice))
                            .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("pro-trial-terms")
                    }
                    if purchases.products.isEmpty && !purchases.loadingProducts {
                        Button(AppText.text("重新載入購買選項")) { Task { await purchases.loadProducts() } }
                            .frame(minHeight:44).accessibilityIdentifier("pro-reload-products")
                    }
                    if let message = purchases.message { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("pro-purchase-message") }
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
        }.task { await purchases.refreshAccess(); await purchases.loadProducts() }
    }
    private func benefit(_ symbol: String,title: String,detail: String) -> some View {
        HStack(alignment:.top,spacing:14) {
            Image(systemName:symbol).font(.title2).foregroundStyle(.blue).frame(width:32)
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
                    HStack { Text(AppText.text(purchases.hasPro ? "Pro 已開通" : "查看 Pro 方案")); Spacer(); Image(systemName:"chevron.right") }
                }.accessibilityIdentifier("pro-open-plans")
                if purchases.hasPro {
                    Button(AppText.text("管理訂閱")) { Task { await purchases.manage() } }
                }
            } footer: { Text(AppText.text("基本導航、官方到站與 3D 追車仍可免費使用。")) }
            Section(AppText.text("通勤")) {
                NavigationLink(AppText.text("常用行程")) { SavedJourneysView(model:model) }
                    .accessibilityIdentifier("pro-saved-journeys")
                if purchases.hasPro {
                    Picker(AppText.text("預設路線偏好"),selection:$commutes.preference) {
                        ForEach(RoutePreference.allCases) { choice in Text(choice.title).tag(choice) }
                    }.accessibilityIdentifier("pro-default-preference")
                } else {
                    Button(AppText.text("個人路線偏好")) { showingPurchase = true }
                }
            }
            if model.planner.started { Text(AppText.text("新偏好會用於下一次規劃。")) .font(.footnote).foregroundStyle(.secondary) }
            Section {
                Button(AppText.text("恢復購買")) { Task { await purchases.restore() } }
                if let message = purchases.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }.navigationTitle(AppText.text("台北公車 Pro")).navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented:$showingPurchase) { ProPurchaseView(purchases:purchases) }
            .task { await purchases.refreshAccess() }
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
                VStack(alignment:.leading,spacing:5) {
                    Label(saved.title,systemImage:saved.symbol).font(.headline)
                    Text((saved.origin?.localizedName ?? AppText.text("目前位置"))+" → "+saved.destination.localizedName)
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(saved.preference.title).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical,4)
            }.onDelete { indices in library.remove(Set(indices.map { library.journeys[$0].id })) }
                .onMove { library.move(from:$0,to:$1) }
            if !purchases.hasPro {
                Button(AppText.text("查看 Pro 方案")) { showingPurchase = true }
                Text(AppText.text("儲存的行程會保留在手機；訂閱到期不會刪除。")) .font(.footnote).foregroundStyle(.secondary)
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
