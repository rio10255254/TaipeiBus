import SwiftUI
import StoreKit
import UserNotifications
import TransitCore

enum ProPlan: String, CaseIterable, Identifiable, Hashable, Sendable {
    case monthly, yearly
    var id: String { rawValue }
    var productID: String { "com.rio10255254.TaipeiBus.pro." + rawValue }
    var title: String { AppText.text(self == .monthly ? "月費方案" : "年費方案") }
    var period: String { AppText.text(self == .monthly ? "每月" : "每年") }
    var unit: String { AppText.text(self == .monthly ? "月" : "年") }
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
    private var statusUpdates: Task<Void,Never>?
    private var expiryCheck: Task<Void,Never>?
    private var accessTask: Task<Void, Never>?
    private var generation = 0
    private var awaitingApproval = false
    var onAccessChange: (() -> Void)?

    init() {
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                switch result {
                case .verified(let transaction) where self.recognizes(transaction):
                    await self.refreshAccess()
                    await transaction.finish()
                case .unverified(let transaction, _) where self.recognizes(transaction):
                    // Never grants access (that reads verified entitlements only); finishing stops
                    // StoreKit redelivering the same failed transaction on every launch.
                    await transaction.finish()
                default:
                    continue
                }
            }
        }
        // Cancellation and billing-state changes may not create a transaction.
        statusUpdates = Task { [weak self] in
            for await status in Product.SubscriptionInfo.Status.updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard case .verified(let transaction) = status.transaction,
                      self.recognizes(transaction) else { continue }
                await self.refreshAccess()
            }
        }
    }
    deinit { updates?.cancel(); statusUpdates?.cancel(); expiryCheck?.cancel(); accessTask?.cancel() }

    private func recognizes(_ transaction: StoreKit.Transaction) -> Bool {
        transaction.productType == .autoRenewable && ProPlan.allCases.contains { $0.productID == transaction.productID }
    }
    func refreshAccess() async {
        generation += 1
        if let accessTask { await accessTask.value; return }
        // All callers await the same refresh, including any status changes received while
        // it is reading. A superseded read must not return to a purchase/restore caller early.
        let operation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let token = self.generation
                await self.readAccess(token: token)
                if token == self.generation { break }
            }
            self.accessTask = nil
        }
        accessTask = operation
        await operation.value
    }
    private func readAccess(token: Int) async {
        var current: StoreKit.Transaction?
        var renewal: Product.SubscriptionInfo.RenewalInfo?
        var grace = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, recognizes(transaction),
                  transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            if current == nil || transaction.purchaseDate > current!.purchaseDate { current = transaction }
        }
        // Subscription state describes expiry, cancellation and billing grace.
        // Use its verified current transaction rather than an older iterator
        // snapshot. If Apple's status query is temporarily unavailable, retain
        // the verified current entitlement (including offline/grace access).
        if let info = products.values.first?.subscription, let statuses = try? await info.status {
            current = nil
            for status in statuses {
                guard status.state == .subscribed || status.state == .inGracePeriod,
                      case .verified(let value) = status.transaction,
                      case .verified(let details) = status.renewalInfo,
                      recognizes(value), value.revocationDate == nil, !value.isUpgraded else { continue }
                if current == nil || value.purchaseDate > current!.purchaseDate {
                    current = value; renewal = details; grace = status.state == .inGracePeriod
                }
            }
        }
        guard token == generation, !Task.isCancelled else { return }
        activePlan = current.flatMap { item in ProPlan.allCases.first { $0.productID == item.productID } }
        hasPro = current != nil; checkingAccess = false
        if hasPro && awaitingApproval { awaitingApproval = false; message = nil }
        isInTrial = false
        if let current, current.offerType == .introductory {
            if #available(iOS 17.2, *) { isInTrial = current.price == .zero }
            else { isInTrial = products[current.productID]?.subscription?.introductoryOffer?.paymentMode == .freeTrial }
        }
        periodEndsAt = grace ? nil : current?.expirationDate
        willAutoRenew = renewal?.willAutoRenew
        onAccessChange?()
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
        busy = true; message = nil; awaitingApproval = false
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
                awaitingApproval = true
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

/// Pro alighting reminder: a local notification shortly before the rider's stop, rescheduled as
/// the live prediction changes, so it still arrives with the phone locked or the app in the
/// background. Nothing leaves the phone.
@MainActor
final class AlightReminder: NSObject, UNUserNotificationCenterDelegate {
    static let leadSeconds: TimeInterval = 90
    private static let identifier = "alight-reminder"
    private var scheduled: (rideID: String, fireAt: Date)?
    private var announced: Set<String> = []
    private(set) var permission: NavigationPermission = .checking
    var onPermissionChange: (() -> Void)?
    var onOpenJourney: (() -> Void)?
    private var permissionGeneration = 0

    private func applyPermission(_ value: NavigationPermission) {
        guard permission != value else { return }
        permission = value
        if value != .allowed { cancel() }
        onPermissionChange?()
    }
    @discardableResult func refreshPermission() async -> NavigationPermission {
        permissionGeneration += 1
        let generation = permissionGeneration
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let value: NavigationPermission
        switch status {
        case .authorized, .provisional, .ephemeral: value = .allowed
        case .denied: value = .denied
        case .notDetermined: value = .notDetermined
        @unknown default: value = .denied
        }
        if generation == permissionGeneration { applyPermission(value) }
        return value
    }
#if DEBUG
    func auditPermission(_ value: NavigationPermission) {
        permissionGeneration += 1; applyPermission(value)
    }
#endif

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    /// Asks once; returns whether notifications may be shown.
    func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        if await refreshPermission() == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        return await refreshPermission() == .allowed
    }
    /// The latest prediction for the current ride. Small changes do not reschedule.
    func update(rideID: String, stopName: String, secondsToAlight: Double, now: Date) {
        guard permission == .allowed, secondsToAlight.isFinite, !announced.contains(rideID) else { return }
        let fireAt = now.addingTimeInterval(max(1, secondsToAlight - Self.leadSeconds))
        if let current = scheduled, current.rideID == rideID, abs(current.fireAt.timeIntervalSince(fireAt)) < 20 { return }
        let content = UNMutableNotificationContent()
        content.title = AppText.text("準備下車")
        content.body = AppText.text("快到「%@」了，準備下車。", stopName)
        content.sound = .default
        content.userInfo = ["navigation": "journey"]
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireAt.timeIntervalSince(now)), repeats: false)))
        scheduled = (rideID, fireAt)
        // Already inside the lead time: it fires now, once for this ride.
        if secondsToAlight <= Self.leadSeconds { announced.insert(rideID) }
    }
    func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        scheduled = nil
    }
    func reset() { cancel(); announced = [] }

    // In the foreground the reminder still shows as a banner, with a firm haptic.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        return [.banner, .list, .sound]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.userInfo["navigation"] as? String == "journey" else { return }
        await MainActor.run { self.onOpenJourney?() }
    }
}
