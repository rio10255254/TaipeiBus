import XCTest
import StoreKit
import StoreKitTest
import TransitCore
@testable import TaipeiBus

@MainActor
final class ProPurchaseTests: XCTestCase {
    private var session: SKTestSession!
    override func setUpWithError() throws {
        let file = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"ProProducts",withExtension:"storekit"))
        session = try SKTestSession(contentsOf:file)
        session.resetToDefaultState(); session.clearTransactions()
        session.disableDialogs = true; session.storefront = "TWN"; session.locale = Locale(identifier:"zh_TW")
        session.timeRate = .realTime
    }
    override func tearDownWithError() throws { session.clearTransactions(); session = nil }
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<80 { if condition() { return }; try await Task.sleep(for:.milliseconds(100)) }
        XCTFail("Apple transaction state did not settle")
    }
    private func waitForApple(_ condition: @escaping () async throws -> Bool) async throws {
        for _ in 0..<80 {
            if try await condition() { return }
            try await Task.sleep(for:.milliseconds(250))
        }
        for plan in ProPlan.allCases {
            if let result = await StoreKit.Transaction.latest(for:plan.productID), case .verified(let item) = result {
                print("Unsettled Apple transaction: \(plan.rawValue), \(item.id), expiry=\(String(describing:item.expirationDate)), revoked=\(String(describing:item.revocationDate))")
            }
        }
        XCTFail("Verified Apple state did not settle after the test-session change")
    }
    func testActualProductsHaveTwoEqualAccessPeriodsAndApprovedPrices() async throws {
        let manager = ProPurchases(); await manager.loadProducts()
        XCTAssertEqual(manager.products.count,2)
        let monthly = try XCTUnwrap(manager.products[ProPlan.monthly.productID])
        let yearly = try XCTUnwrap(manager.products[ProPlan.yearly.productID])
        XCTAssertTrue(ProPlan.monthly.accepts(monthly)); XCTAssertTrue(ProPlan.yearly.accepts(yearly))
        XCTAssertEqual(monthly.price,Decimal(39)); XCTAssertEqual(yearly.price,Decimal(290))
        XCTAssertEqual(monthly.subscription?.subscriptionGroupID,yearly.subscription?.subscriptionGroupID)
        for product in [monthly,yearly] {
            let offer = try XCTUnwrap(product.subscription?.introductoryOffer)
            XCTAssertEqual(offer.paymentMode,.freeTrial); XCTAssertEqual(offer.period.value,1); XCTAssertEqual(offer.period.unit,.week)
        }
        XCTAssertTrue(manager.offersSevenDayTrial(.monthly)); XCTAssertTrue(manager.offersSevenDayTrial(.yearly))
        await manager.refreshAccess(); XCTAssertFalse(manager.hasPro)
    }
    func testPurchaseAndRecreatedManagerRestoreFromAppleWithoutAPaidFlag() async throws {
        let manager = ProPurchases(); await manager.loadProducts(); await manager.refreshAccess()
        await manager.purchase(.monthly)
        XCTAssertTrue(manager.hasPro); XCTAssertEqual(manager.activePlan,.monthly); XCTAssertFalse(manager.busy)
        XCTAssertTrue(manager.isInTrial); XCTAssertNotNil(manager.periodEndsAt)
        let recreated = ProPurchases(); await recreated.refreshAccess()
        XCTAssertTrue(recreated.hasPro,"A new app instance reads Apple's entitlement, not an app-owned paid flag")
        await recreated.restore(); XCTAssertTrue(recreated.hasPro)
    }
    func testRefundAndExpirationRevokeAccessWithoutDeletingSavedJourneys() async throws {
        let suite = "ProRefundTests."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite)); defer { defaults.removePersistentDomain(forName:suite) }
        let library = CommuteLibrary(defaults:defaults)
        XCTAssertTrue(library.store(title:"回家",symbol:"house.fill",origin:nil,
            destination:TravelPlace(name:"內湖",address:"",coordinate:Coordinate(latitude:25.0837,longitude:121.5947)),preference:.lessWalking))
        let manager = ProPurchases(); await manager.loadProducts(); await manager.purchase(.yearly)
        XCTAssertTrue(manager.hasPro)
        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == ProPlan.yearly.productID })
        try session.refundTransaction(identifier:transaction.identifier)
        try await waitUntil { !manager.hasPro }
        await manager.purchase(.monthly); XCTAssertTrue(manager.hasPro)
        try session.expireSubscription(productIdentifier:ProPlan.monthly.productID)
        try await waitForApple { await manager.refreshAccess(); return !manager.hasPro }
        XCTAssertFalse(manager.hasPro)
        XCTAssertNil(manager.activePlan)
        XCTAssertEqual(CommuteLibrary(defaults:defaults).journeys.count,1)
    }
    func testCancelledAndFailedPurchasesDoNotUnlockOrRemainBusy() async throws {
        let manager = ProPurchases(); await manager.loadProducts()
        try await session.setSimulatedError(.generic(.userCancelled),forAPI:.purchase)
        await manager.purchase(.monthly)
        XCTAssertFalse(manager.hasPro); XCTAssertFalse(manager.busy); XCTAssertNil(manager.message)
        try await session.setSimulatedError(.generic(.notAvailableInStorefront),forAPI:.purchase)
        await manager.purchase(.monthly)
        XCTAssertFalse(manager.hasPro); XCTAssertFalse(manager.busy); XCTAssertNotNil(manager.message)
        try await session.setSimulatedError(nil,forAPI:.purchase)
    }
    func testAskToBuyWaitsForApprovalAndReceivesTransactionUpdate() async throws {
        let manager = ProPurchases(); await manager.loadProducts(); session.askToBuyEnabled = true
        await manager.purchase(.monthly)
        XCTAssertFalse(manager.hasPro); XCTAssertFalse(manager.busy)
        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == ProPlan.monthly.productID })
        try session.approveAskToBuyTransaction(identifier:transaction.identifier)
        try await waitUntil { manager.hasPro }
        XCTAssertNil(manager.message,"Approved purchases must clear the pending message")
    }
    func testCancellingRenewalPreservesThePaidPeriodAndPlansDoNotStack() async throws {
        let manager = ProPurchases(); await manager.loadProducts(); await manager.purchase(.monthly)
        // Move beyond the free offer so this case tests a paid billing period.
        try session.forceRenewalOfSubscription(productIdentifier:ProPlan.monthly.productID)
        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == ProPlan.monthly.productID })
        try session.disableAutoRenewForTransaction(identifier:transaction.identifier)
        await manager.refreshAccess(); XCTAssertTrue(manager.hasPro)
        await manager.purchase(.yearly); await manager.refreshAccess()
        XCTAssertTrue(manager.hasPro)
        let info = try XCTUnwrap(manager.products[ProPlan.yearly.productID]?.subscription)
        let active = try await info.status
        XCTAssertLessThanOrEqual(active.filter { $0.state == .subscribed }.count,1)
    }
    func testTrialCancellationHasNoPaidRenewalAndCannotBeRepeatedOnAnnualPlan() async throws {
        let manager = ProPurchases(); await manager.loadProducts(); await manager.purchase(.monthly)
        XCTAssertTrue(manager.isInTrial)
        let transaction = try XCTUnwrap(session.allTransactions().last { $0.productIdentifier == ProPlan.monthly.productID })
        try session.disableAutoRenewForTransaction(identifier:transaction.identifier)
        try await waitForApple { await manager.refreshAccess(); return manager.willAutoRenew == false }
        XCTAssertTrue(manager.hasPro); XCTAssertEqual(manager.willAutoRenew,false)
        try session.expireSubscription(productIdentifier:ProPlan.monthly.productID)
        try await waitForApple { await manager.refreshAccess(); return !manager.hasPro }
        XCTAssertFalse(manager.hasPro)
        await manager.loadProducts()
        XCTAssertFalse(manager.offersSevenDayTrial(.monthly)); XCTAssertFalse(manager.offersSevenDayTrial(.yearly))
        await manager.purchase(.yearly); XCTAssertTrue(manager.hasPro); XCTAssertFalse(manager.isInTrial)
    }
    func testTrialRenewalUsesTheApprovedMonthlyPrice() async throws {
        let manager = ProPurchases(); await manager.loadProducts(); await manager.purchase(.monthly)
        XCTAssertTrue(manager.isInTrial)
        try session.forceRenewalOfSubscription(productIdentifier:ProPlan.monthly.productID)
        try await waitForApple { await manager.refreshAccess(); return manager.hasPro && !manager.isInTrial }
        XCTAssertTrue(manager.hasPro); XCTAssertFalse(manager.isInTrial)
        var transaction: StoreKit.Transaction?
        try await waitForApple {
            for await value in StoreKit.Transaction.currentEntitlements {
                if case .verified(let item) = value, item.productID == ProPlan.monthly.productID { transaction = item }
            }
            if #available(iOS 17.2, *) { return transaction?.price == Decimal(39) }
            return transaction?.offerType == nil
        }
        if #available(iOS 17.2, *) { XCTAssertEqual(try XCTUnwrap(transaction).price,Decimal(39)) }
    }
    func testVerifiedBillingGraceKeepsAccessAndRecoversWithoutAnotherPurchase() async throws {
        // Accelerated time applies when the transaction is created; changing it
        // after purchase would leave the existing real-time expiry untouched.
        session.timeRate = .oneSecondIsOneDay
        session.billingGracePeriodIsEnabled = true
        let manager = ProPurchases(); await manager.loadProducts(); await manager.purchase(.monthly)
        let original = try XCTUnwrap(session.allTransactions().last)
        try session.enableAutoRenewForTransaction(identifier:original.identifier)
        try await waitForApple { await manager.refreshAccess(); return manager.hasPro && !manager.isInTrial }
        session.shouldEnterBillingRetryOnRenewal = true
        let info = try XCTUnwrap(manager.products[ProPlan.monthly.productID]?.subscription)
        var sawGrace = false
        for _ in 0..<80 {
            let statuses = try await info.status
            if statuses.contains(where:{ $0.state == .inGracePeriod }) { sawGrace = true; break }
            try await Task.sleep(for:.milliseconds(500))
        }
        XCTAssertTrue(sawGrace,"Apple's test environment must actually enter billing grace")
        guard sawGrace else { return }
        await manager.refreshAccess(); XCTAssertTrue(manager.hasPro)
        session.shouldEnterBillingRetryOnRenewal = false
        let transaction = try XCTUnwrap(session.allTransactions().max(by:{ $0.identifier < $1.identifier }))
        try session.resolveIssueForTransaction(identifier:transaction.identifier)
        await manager.refreshAccess(); XCTAssertTrue(manager.hasPro)
    }
    func testCommutePersistenceCurrentOriginAndPreferencesAreRealAndBounded() throws {
        let suite = "ProPurchaseTests."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let library = CommuteLibrary(defaults:defaults)
        let destination = TravelPlace(name:"內湖",address:"",coordinate:Coordinate(latitude:25.0837,longitude:121.5947))
        XCTAssertTrue(library.store(title:"回家",symbol:"house.fill",origin:nil,destination:destination,preference:.fewerTransfers))
        let restored = CommuteLibrary(defaults:defaults)
        XCTAssertEqual(restored.journeys.count,1); XCTAssertNil(restored.journeys[0].origin)
        XCTAssertEqual(restored.journeys[0].preference,.fewerTransfers)
        XCTAssertGreaterThan(RoutePreference.fewerTransfers.applying(to:.init()).transferPenaltySeconds,LiveSettings.Planning().transferPenaltySeconds)
        XCTAssertGreaterThan(RoutePreference.lessWalking.applying(to:.init()).walkingWeight,LiveSettings.Planning().walkingWeight)
        XCTAssertLessThan(RoutePreference.faster.applying(to:.init()).transferPenaltySeconds,LiveSettings.Planning().transferPenaltySeconds)
        XCTAssertFalse(library.store(title:"錯誤",symbol:"house.fill",origin:nil,
            destination:TravelPlace(name:"錯誤",address:"",coordinate:Coordinate(latitude:0,longitude:0)),preference:.balanced))
        restored.remove(Set(restored.journeys.map(\.id))); XCTAssertTrue(CommuteLibrary(defaults:defaults).journeys.isEmpty)
    }
}
