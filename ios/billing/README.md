# TaipeiBus Pro

Built on TestFlight 1.3.8 (85.1.0). Public navigation, official arrivals, live
vehicle tracking and 3D rendering stay free. Both subscriptions unlock only new
saved commute shortcuts (up to 50) and personal route preferences.

| Product | Taiwan renewal price | Introductory offer |
| --- | --- | --- |
| `com.rio10255254.TaipeiBus.pro.monthly` | NT$39 / month | 7 days free |
| `com.rio10255254.TaipeiBus.pro.yearly` | NT$290 / year | 7 days free |

Apple determines eligibility once per subscription group. Product prices and
offers shown in the app come from StoreKit, never from a hardcoded price label.
The paywall states the post-trial price and that cancellation at least 24 hours
before the trial ends avoids charging. Purchased rights come from verified
current entitlements; grace access is retained when Apple reports it.

Saved destinations remain local and are retained after expiry/refund.
No developer account service, card handling, app-owned paid flag or server
credentials are added. Navigation previews remain previews after tapping a
commute shortcut; starting a journey still requires the existing Start action.

`setup.rb` creates a hosted StoreKit test target on the macOS runner. The
configuration is copied only into the test bundle, not the distributed app.
Run the existing iPhone workflow with `billing_tests=true` for actual StoreKit
transactions and native light/dark walkthroughs. TestFlight uses Apple's
sandbox, not this local StoreKit configuration; do not expect local test
transactions to carry over to TestFlight.

The Apple preparation script creates draft groups/products, Taiwan prices,
localized descriptions and introductory offers. It never submits App Review,
accepts legal agreements, enters bank/tax details or charges a customer. First
commercial release must include Apple's review of these subscriptions with a
new app version. Account Holder agreements, tax and banking must be current.

Sources: [Introductory offers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-introductory-offers-for-auto-renewable-subscriptions/),
[StoreKit eligibility](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/iseligibleforintrooffer),
[Subscription setup](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases/).
