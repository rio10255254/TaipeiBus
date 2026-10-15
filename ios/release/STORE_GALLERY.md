# Approved App Store gallery

The nine approved images are now attached to the paused **1.8.0 (124.1.0)**
App Store draft. Their original capture provenance below is retained; no pixels
were changed. See `app-store-1.8.0-draft-receipt.json` for Apple's exact metadata,
build, processed-image checksums and ordering confirmation. Release remains manual
and this version has not been submitted for review.

TestFlight invitation images are taken from the latest approved App Store version
in Ready for Distribution, not the selected beta build. A new build or an edited
store draft does not replace those images. See Apple's [test information guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/).

## Original approved gallery for 1.6.1

The approved nine-image gallery accompanies 1.6.1 (98.1.0). Its exact order is
in `app-store.zh-Hant.json`; the source and rendered SHA-256 values, dimensions,
capture runs and crop descriptions are in `screenshots/manifest.json`.

The first three images feature the 3D bus, estimated metro position and actual
Dynamic Island. All six user-provided app screenshots are retained. Two native
captures add route comparison and walking; the Dynamic Island image also shows
the actual Pro paywall with monthly NT$39, annual NT$390 and seven-day trial.
Only the user's Dynamic Island region is included from their Home Screen.
Unrelated app icons and notifications are excluded. Metro positions are labelled
as estimates; haptic reminders depend on iPhone notification and haptic settings.

The six physical-device originals are 588 × 1280 compressed images, approved by
the user for publication. Their fine-text resolution is limited by those originals.
All final assets are RGB 1320 × 2868 PNGs. No app controls, arrival values or
vehicle positions were fabricated or redrawn. The route-comparison image omits
only the simulator status bar so its UTC clock does not conflict with Taipei ETA.

The older renderer and `screenshot-sources` below belong to the 1.2.0 gallery;
do not use them to replace the approved 1.6.1 images. The release uploader reads
only the nine names in `screenshotOrder`, regardless of retained historical files.

## Historical 1.2.0 capture workflow

Five reviewed images accompany the exact 1.2.0 (52.1.0) submission. Capture
provenance is recorded in `screenshots/manifest.json`; Apple confirmation is
saved in `app-store-1.2.0-receipt.json`.

The gallery uses unmodified native 1320 × 2868 iPhone screenshots. Short titles,
captions, a neutral background and an outer frame are rendered around the app.
No vehicle positions, arrival values, route choices or app controls are drawn
into the app screenshot. Each source image is retained in `screenshot-sources`;
`screenshots/manifest.json` records its SHA-256 and caption.

Run with Node.js, Playwright and an installed Microsoft Edge browser:

```sh
node ios/release/render-gallery.cjs ios/release/screenshot-sources work/store-gallery
```

Review new renders before copying the PNGs into `screenshots`, and retain the
capture run, source commit, exact build and original-source hashes in the saved
manifest. The files listed in `app-store.zh-Hant.json` are the uploaded gallery.
HTML files are local previews, not Apple assets. The uploader only
changes screenshots on the matching editable update. Verification reads back
the exact metadata, screenshot names, order, checksums, dimensions, Taiwan-only
availability, free price and automatic-release setting before submission.

Commercial captures use the app's live official bus data and Apple walking
routes. Test-only selection switches can open an existing stop or bus; vehicle,
ETA and itinerary fixtures are prohibited in `AppStoreScreenshotTests`.
Passenger GPS is simulated; the station-walking capture uses a controlled
passenger/stop setup with actual Apple walking directions. No bus position,
plate or arrival time is invented for a store image.

Animation QA is separate from commercial capture. It covers map travel and
return framing, Reduce Motion, a continuously moving 2,500-vehicle workload,
real feed refresh while following one bus, complete trip actions, station/route
return paths, in-app walking, language switching and light/dark switching.
Simulator encoding times and recorded transitions do not establish the display
frame rate on a physical iPhone.
