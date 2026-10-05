# App Store gallery for 1.1.8

The gallery uses unmodified native 1320 × 2868 iPhone screenshots. Short titles,
captions, a neutral background and an outer frame are rendered around the app.
No vehicle positions, arrival values, route choices or app controls are drawn
into the app screenshot. Each source image is retained in `screenshot-sources`;
`screenshots/manifest.json` records its SHA-256 and caption.

Run with Node.js, Playwright and an installed Microsoft Edge browser:

```sh
node ios/release/render-gallery.cjs ios/release/screenshot-sources ios/release/screenshots
```

The resulting PNG files listed in `app-store.zh-Hant.json` are the uploaded
gallery. HTML files are local previews, not Apple assets. The uploader only
changes screenshots on the matching editable update. Verification reads back
the exact metadata, screenshot names, order, checksums, dimensions, Taiwan-only
availability, free price and automatic-release setting before submission.

Commercial captures use the app's live official bus data and Apple walking
routes. Test-only selection switches can open an existing stop or bus; vehicle,
ETA and itinerary fixtures are prohibited in `AppStoreScreenshotTests`.

Animation QA is separate from commercial capture. It covers map travel and
return framing, Reduce Motion, a continuously moving 2,500-vehicle workload,
real feed refresh while following one bus, complete trip actions, station/route
return paths, in-app walking, language switching and light/dark switching.
Simulator encoding times and recorded transitions do not establish the display
frame rate on a physical iPhone.
