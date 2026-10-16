# 1.8.5 contextual journey planning

The previous search could discard a useful service before considering cycling to it, and direct cycling used a different recommendation threshold from transit connections. The revised search includes bike access, outdoor transfers and egress in the transit graph, then verifies the complete streets before publishing usable choices. Walking, direct cycling and mixed journeys share the same comparison policy.

## Behavior

- Elapsed and arrival time contain actual travel, station access, handling and reachable waiting. Walking, transfers, rental count, unknown waits and sparse/older dock reports affect recommendation order without becoming fictional minutes on the clock.
- Current official departures are authoritative. Platform changes and upstream uncertainty use shared boarding margins. Verified longer streets, changed peak headways and missed last trains are checked for every supported rail line.
- Initial search uses current cached supply. Fresh reports reorder recommendations immediately, and a new report can trigger another integrated search without waiting for the old one-minute search timer. Inspected routes and their camera remain selected.
- Initial checked options publish promptly. Leading cycling choices subsequently compare up to three actual dock pairs per connector; a changed access can catch a different departure, so alternatives are ranked as whole journeys.
- Query work is bounded by distance and available modes. Every service remains searchable; repeated boarding platforms are reduced to arrival, walking and boarding-location representatives before expanding bus changes. Timetable lower bounds skip candidates that cannot improve the retained family score or geometric tradeoffs. Nearby dock queries are shared only within one availability snapshot.
- Street results are shared by endpoints, mode and language, expire after 15 minutes and have a 512-entry bound. Walking guidance requests bypass that cache.
- A separate planner evaluates the remaining trip during foreground walking when the phone has a recent accurate fix. It cannot mutate the active route, map, walking progress, confirmed bus or train. Meaningful improvements need at least four minutes or 12 percent savings; an unusable future connection can justify a replacement without promising a faster arrival.
- A small optional prompt offers the new route. Only tapping Switch adopts it; dismissing keeps the trip, suppresses that suggestion for five minutes and boarding clears it. Whole-trip alternatives are suppressed onboard, while cycling or near the pickup dock. Existing dock-replacement controls handle an already rented bike.
- Walking to pickup, riding and walking after return use separate remaining-time calculations. Unknown positions and waits do not become precise arrival promises.

## Verification and limits

Evidence is recorded in `contextual-journey-1.8.5-readiness.json` after the checks finish. The test matrix covers the frozen bundled city catalog with official travel profiles, fresh/stale/empty supply, direct cycling, two bus rides with cycling at both ends, independent route evaluation, last trains on every rail line, cache expiry, several street-verified dock pairs, StoreKit and native light/dark Chinese/English interactions.

City performance and integration fixtures use explicitly controlled availability, not a replay of historical station counts. Real MapKit directions are also checked separately. These are simulator checks, not a claim that every physical route has been ridden. Search remains bounded and cannot prove a global optimum; future bikes/docks cannot be reserved, and counts or street access may change.

Only TestFlight is authorized for this release. The App Store submission and billing settings stay paused/unchanged.

## Primary research used

- Microsoft Research, Round-Based Public Transit Routing: https://www.microsoft.com/en-us/research/publication/round-based-public-transit-routing/
- OpenTripPlanner, RouteRequest: https://docs.opentripplanner.org/en/latest/RouteRequest/
