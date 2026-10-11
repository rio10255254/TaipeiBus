import SwiftUI
import StoreKit
import TransitCore

enum ProPlan: String, CaseIterable, Identifiable, Hashable, Sendable {
    case monthly, yearly
    var id: String { rawValue }
    var productID: String { "com.rio10255254.TaipeiBus.pro." + rawValue }
    var title: String { AppText.text(self == .monthly ? "月費方案" : "年費方案") }
    var period: String { AppText.text(self == .monthly ? "每月" : "每年") }
    func accepts(_ product: Product) -> Bool {
        guard product.id == productID, product.type == .autoRenewable,
              let period = product.subscription?.subscriptionPeriod, period.value == 1 else { return false }
        return period.unit == (self == .monthly ? .month : .year)
    }
}

/// Access comes only from Apple's verified, current subscription entitlements.
/// No stored paid flag, app account, billing server or payment credentials.
@MainActor
final class ProPurchases: ObservableObject {
    @Published private(set) var hasPro = false
    @Published private(set) var checkingAccess = true
    @Published private(set) var products: [String:Product] = [:]
    @Published private(set) var loadingProducts = false
    @Published private(set) var busy = false
    @Published private(set) var activePlan: ProPlan?
    @Published private(set) var eligibleTrialPlans: Set<ProPlan> = []
    @Published private(set) var isInTrial = false
    @Published private(set) var periodEndsAt: Date?
    @Published private(set) var willAutoRenew: Bool?
    @Published var message: String?
    private var updates: Task<Void,Never>?
    private var expiryCheck: Task<Void,Never>?
    private var generation = 0

    init() {
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard case .verified(let transaction) = result,
                      self.recognizes(transaction) else { continue }
                await self.refreshAccess()
                await transaction.finish()
            }
        }
    }
    deinit { updates?.cancel(); expiryCheck?.cancel() }

    private func recognizes(_ transaction: StoreKit.Transaction) -> Bool {
        transaction.productType == .autoRenewable && ProPlan.allCases.contains { $0.productID == transaction.productID }
    }
    func refreshAccess() async {
        generation += 1; let token = generation
        var plans: Set<ProPlan> = []
        var current: StoreKit.Transaction?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, recognizes(transaction),
                  transaction.revocationDate == nil, !transaction.isUpgraded,
                  let plan = ProPlan.allCases.first(where:{ $0.productID == transaction.productID }) else { continue }
            // Local StoreKit and the App Store may briefly retain an entitlement at
            // the expiry boundary. A verified grace state still grants access.
            if let end = transaction.expirationDate, end <= Date(),
               let info = products[plan.productID]?.subscription,
               let statuses = try? await info.status {
                let grace = statuses.contains { status in
                    guard status.state == .inGracePeriod,
                          case .verified(let value) = status.transaction,
                          case .verified = status.renewalInfo else { return false }
                    return value.productID == transaction.productID && value.revocationDate == nil
                }
                if !grace { continue }
            }
            plans.insert(plan)
            if current == nil || transaction.purchaseDate > current!.purchaseDate { current = transaction }
        }
        guard token == generation, !Task.isCancelled else { return }
        activePlan = plans.contains(.yearly) ? .yearly : plans.contains(.monthly) ? .monthly : nil
        hasPro = !plans.isEmpty; checkingAccess = false
        isInTrial = false
        if let current, current.offerType == .introductory {
            if #available(iOS 17.2, *) { isInTrial = current.price == .zero }
            else { isInTrial = products[current.productID]?.subscription?.introductoryOffer?.paymentMode == .freeTrial }
        }
        periodEndsAt = current?.expirationDate; willAutoRenew = nil
        if let plan = activePlan, let info = products[plan.productID]?.subscription,
           let statuses = try? await info.status,
           let status = statuses.first(where:{ $0.state == .subscribed || $0.state == .inGracePeriod }),
           case .verified(let renewal) = status.renewalInfo, token == generation {
            willAutoRenew = renewal.willAutoRenew
        }
        guard token == generation else { return }
        await refreshTrialEligibility()
        guard token == generation else { return }
        expiryCheck?.cancel(); expiryCheck = nil
        if let end = periodEndsAt, end > Date() {
            let delay = end.timeIntervalSinceNow + 2
            expiryCheck = Task { [weak self] in
                do { try await Task.sleep(for:.seconds(delay)) } catch { return }
                await self?.refreshAccess()
            }
        }
    }
    func offersSevenDayTrial(_ plan: ProPlan) -> Bool { eligibleTrialPlans.contains(plan) && !hasPro }
    private func refreshTrialEligibility() async {
        var eligible: Set<ProPlan> = []
        for plan in ProPlan.allCases {
            guard let info = products[plan.productID]?.subscription,
                  let offer = info.introductoryOffer, offer.paymentMode == .freeTrial,
                  offer.period.unit == .week, offer.period.value == 1,
                  await info.isEligibleForIntroOffer else { continue }
            eligible.insert(plan)
        }
        eligibleTrialPlans = eligible
    }
    func loadProducts() async {
        guard !loadingProducts else { return }
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            let values = try await Product.products(for:ProPlan.allCases.map(\.productID))
            guard !Task.isCancelled else { return }
            products = Dictionary(values.filter { product in
                ProPlan.allCases.contains { $0.accepts(product) }
            }.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first })
            await refreshAccess()
        } catch {
            // Keep an already-loaded offer during a temporary network failure.
            if products.isEmpty { message = AppText.text("購買選項尚未載入，請稍後再試。") }
        }
    }
    func purchase(_ plan: ProPlan) async {
        guard !busy, let product = products[plan.productID], plan.accepts(product) else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result, recognizes(transaction),
                      transaction.productID == plan.productID else {
                    message = AppText.text("Apple 尚未確認購買，請稍後再試。")
                    return
                }
                await refreshAccess()
                await transaction.finish()
            case .pending:
                message = AppText.text("正在等待 Apple 確認購買。")
            case .userCancelled:
                break
            @unknown default:
                message = AppText.text("購買尚未完成，請稍後再試。")
            }
        } catch let error as SKError where error.code == .paymentCancelled {
            // Cancellation is a normal exit and never blocks the free app.
        } catch StoreKitError.userCancelled {
        } catch {
            message = AppText.text("購買尚未完成，請稍後再試。")
        }
    }
    func restore() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refreshAccess()
            message = AppText.text(hasPro ? "已恢復 Pro 訂閱。" : "這個 Apple 帳號目前沒有可恢復的 Pro 訂閱。")
        } catch { message = AppText.text("暫時無法確認購買，請稍後再試。") }
    }
    func manage() async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where:{ $0.activationState == .foregroundActive }) else { return }
        do { try await AppStore.showManageSubscriptions(in:scene); await refreshAccess() }
        catch { message = AppText.text("請到 App Store 的訂閱項目管理 Pro。") }
    }
}
