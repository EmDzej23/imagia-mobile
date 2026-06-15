# Imagia Mobile — Progress & Handoff

Detailed running notes so work can resume after a context reset. Last updated: **2026-06-15**.

## Repos & architecture
- **`imagia-mobile`** (this repo): Flutter (iOS + Android) app. Bundle/package `com.imagiastore.studio`. Dark theme, Inter font, Riverpod, go_router, dio.
- **`foto-mozaik`** (sibling: `/Users/marko/radni/foto-mozaik`): the Next.js backend + web app. The mobile app calls its **production API** at `https://studio.imagiastore.com` (bearer-token / better-auth). Server pieces we edit live here.
- Render: server `/api/render` (sync mode) proxies to a **Cloud Run** render service; output is a Vercel Blob, served via `/api/mosaic-image/{token}?maxSize=` (public) and `/api/download/{token}` (auth).
- Payments: **Creem** (hosted checkout in a webview; success via redirect).
- Push: **FCM** (firebase_messaging client; firebase-admin server in `foto-mozaik/lib/push.ts`).
- The mosaic algorithm is a bit-exact Dart port of the web (`lib/mosaic/*`), validated by `test/`.

## Conventions / gotchas (important)
- `flutter analyze` is kept clean **except ~8 pre-existing `info` lints** (null-aware suggestions, `use_build_context_synchronously` in downloads/preview, `prefer_initializing_formals` in analyze.dart). Zero errors/warnings is the bar.
- `AppSpacing` has `x1,x2,x3,x4,x6,x8,x12` — **no x5/x7** (common mistake → undefined_getter).
- **AVIF is not decodable by Flutter** — convert to JPEG/PNG and bundle.
- **Don't put a `TickerProvider` (animation) on a `ConsumerState`** — TickerMode changes during route transitions resume Riverpod subscriptions mid-build → "setState during build" crash. Put the ticker in a plain child `StatefulWidget` (see `_AnimatedMosaicPreview` in studio_screen).
- **Don't have an autoDispose provider `ref.watch` another provider that changes** if widgets with tickers/route-transitions watch it — same crash class. (Fixed `projectThumbnailsProvider` by making it a `.family` keyed by URL string.)
- Text rendered in `MaterialApp.builder` (above the Navigator) shows **yellow debug underlines** — wrap in `Material(type: transparency)` (see `RenderIndicatorOverlay`).
- **Never read/listen to the go_router `routerDelegate`/`routeInformationProvider` from inside `MaterialApp.builder`** — the overlay is a descendant of what the delegate builds, so it re-enters the build → `!_dirty` assertion crash. Use a provider flag set by the target screen instead (see the indicators section).
- **Benign iOS console noise to ignore:** UIKit `NSLayoutConstraint` "unsatisfiable / will attempt to recover" logs about `SystemInputAssistantView` (keyboard) and `_UIToolbarContentView`/`_UIButtonBarStackView`/`_UIModernBarButton` (the keyboard input-accessory toolbar) — these come from the OS keyboard and the WKWebView (Creem checkout page), not our code. No fix; not in our control. Decided to leave the Creem checkout as an embedded webview.
- Font/asset/pubspec changes require a **full rebuild** (not hot reload). The user often runs the app **standalone (no `flutter run` attach)** because of a local **VM-service/DDS attach failure** (utun/VPN interfering with 127.0.0.1) — so code changes need a fresh build/install to appear. `flutter run --no-dds` / disabling VPN / iCloud Private Relay is the workaround; the app itself is fine.

## Memory files (auto-loaded)
`~/.claude/projects/-Users-marko-radni-imagia-mobile/memory/`: `imagia-mobile-flutter-port.md`, `foto-mozaik-api-contract.md`, **`pod-prodigi-plan.md`** (the POD feature in full detail — read it).

---

## Recent work (this session)

### Push notifications (iOS)
- Root cause of "no push": the **APNs Auth Key (.p8) wasn't uploaded to Firebase** (user fixed in Firebase console → Cloud Messaging). One key covers sandbox + production.
- After a rebuild, push broke again because reinstall **rotated the FCM token**; `lib/services/push_service.dart` now **waits for the APNs token** (polls `getAPNSToken` up to ~6s) before `getToken`, re-registers on token refresh, and **logs** `[push]` permission/APNs/FCM/register status.
- **Foreground notifications**: `lib/services/notifications.dart` `showRenderDone` now sets `DarwinNotificationDetails(presentAlert/presentBanner/presentSound: true)` so the local "mosaic ready" banner shows even when the app is open. FCM foreground presentation left OFF to avoid duplicates (local notif covers in-app; FCM covers backgrounded).

### Design system / UI modernization
- `lib/theme/app_colors.dart`: added `AppGradients` (brand indigo→violet `gradientStart`/`gradientEnd`, `surface` gradient, `elevation()` shadow, `glow()`).
- `AppRadius.card` bumped 12 → 16.
- `lib/widgets/`: `PrimaryButton` (gradient + glow + press), `pressable.dart` (`PressableScale`), `app_card.dart` (`AppCard` — gradient surface + shadow + optional `clip`/`onTap`; clip applies only to child so shadow isn't clipped), `app_progress_bar.dart` (gradient fill), `shimmer.dart` (`Shimmer`, `SkeletonBox`, `GalleryGridSkeleton`, `DownloadsListSkeleton`, `GradientShimmerBox`, `ShimmerNetworkImage`).
- `lib/services/haptics.dart` (`Haptics.tap/impact/selection/success`).
- `AppCard` applied to gallery cards, downloads items, account (profile/package/link tiles), help steps, sample-pack tiles. Token package price chip uses brand gradient. Gallery FAB is a gradient pill.
- Onboarding: `lib/screens/onboarding/onboarding_screen.dart` (3-slide carousel, animated mosaic hero), shown once at first sign-in (flag in `lib/services/app_prefs.dart`).
- Animated token counter in account; render-complete plays `Haptics.success()`.

### Inter font (bundled)
- Real Inter TTFs (Regular/Medium/SemiBold/Bold) in `assets/fonts/`, declared in pubspec `fonts:`. `AppTypography` + `AppTheme` use `fontFamily: 'Inter'`. **Removed `google_fonts` dependency.** Video text uses `fontFamily: 'Inter'` too.

### Native legal/help
- `lib/screens/legal/legal_screen.dart` (`LegalScreen.privacy()` / `.terms()`), `help_screen.dart`. Replaced the webview approach (deleted `web_page_screen.dart`). Linked from Account.

### Studio preview
- Tile-drift reveal on first plan appearance; **commit-only cross-fade** for density/variety/mode changes (`_AnimatedMosaicPreview` + `_PlanLayer` in `studio_screen.dart`, `appear` param on `MosaicPreviewPainter`). Tint changes stay instant.
- Loupe (zoom popup) is **pannable** (drag) and **tap-a-tile reveals it** in the tiles strip.

### Video export (`lib/video/`, `lib/screens/video/`)
- Every style is a branded 9:16 "poster": procedural **wall** background, **caption** animated above, **branding lockup** below (logo on top → "Imagia" → slogan **"Made of moments"**), all Inter.
- **Per-tile overlay** for Burst & Photo wall (each tile carries its slice of the base overlay so no ghost base image floats in; reconstructs the preview's overlay as tiles settle). Deep-zoom/morph keep the full overlay.
- reelPoster default; changing style/quality **resets** the generated video. Foreground video-player setState-async bug fixed.

### Gallery / downloads
- Downloads: full account history (`DownloadsApi.listAll` walks all pages). `GradientShimmerBox`/`ShimmerNetworkImage` placeholders.
- Project cards show the **base photo**: server `/api/projects` now returns `baseImageUrl`; mobile `projectThumbnailsProvider` (a **`.family` keyed by joined URLs**) batch-fetches thumbnails via `tile-thumb-batch`; `_ProjectGrid` watches once and passes down (avoids per-card provider crash).

### Tile upload
- Compression **serialized** in `ImageService` (native codec not reentrant). Loader shows **before** progress (set `isUploadingTiles` before the picker so the post-picker resolve gap isn't blank; indeterminate until first tile). Tile limit 500 → **2000**; upload concurrency 8 → 16.
- **Sample tiles**: `GET /api/sample-tiles?folder=`; imported like a restore (reuse blobUrl, analyze locally). `lib/data/sample_packs.dart`, `lib/widgets/sample_pack_sheet.dart`, `loadSampleTiles` in studio controller.

### Render resolution fix (was producing 8000px)
- The mobile sent the plan with the default `outputWidth: 8000` (`lib/mosaic/shared.dart`); the server renders at the plan's `outputWidth`. Web sets it to the configured max at export.
- Fix: `lib/api/features_api.dart` + `maxResolutionProvider` fetch `/api/features` `maxResolution` (currently **20000**). `RenderApi.render(outputLongSide:)` overrides the plan's output dims so the **long side = maxResolution**. Used by the export render (`render_controller`). Admin/db settings (NB defaults in `lib/features.ts` are swapped vs. the values): **In-App Max (`getMaxResolution`) = 20000, Print Max (`getMaxResolutionPrint`) = 12000**. The print flow renders at `getMaxResolutionPrint()` server-side (see POD below).

### Global indicators (render + print job)
- `lib/widgets/render_indicator.dart` (`RenderIndicatorOverlay`) wrapped via `MaterialApp.builder`. Shows tappable gradient pills on every screen for **two** long-running jobs, stacked if both: a mosaic render (`renderControllerProvider.phase == rendering` → tap `/create/export`) and a **print-order finalisation** (`printJobControllerProvider.isProcessing` → tap pushes `OrderProcessingScreen`).
- Each pill hides on its own screen via a provider flag set by that screen on mount/unmount — `onRenderScreenProvider` (export) and `onPrintProcessingScreenProvider` (processing). **Do NOT listen to `router.routerDelegate`/`routeInformationProvider` from inside `MaterialApp.builder`** — it re-enters the build and crashes (`!_dirty`). The flag is toggled in `initState` (post-frame) + `dispose` (post-frame, via a `ProviderContainer` captured in `didChangeDependencies`).
- `RenderController.start()` no-ops if already rendering; studio Export button disabled + "Rendering…" while busy.

---

## Print-on-demand (Prodigi) — summary (full detail in `pod-prodigi-plan.md` memory)
- **Web already has a complete Printful POD** (`foto-mozaik/lib/print-products.ts`, `/api/print/*`). Decision: **leave Printful untouched**, build a **parallel Prodigi** stack under `/api/print/prodigi/*` + `prodigi_orders` table. Mobile uses Prodigi.
- Products (3 types × 3 orientations; poster excluded from app via `kAvailablePrintTypes`):
  - Canvas `GLOBAL-SLIMCAN-40X40` (sq) / `GLOBAL-SLIMCAN-32X40` (portrait+landscape, landscape rotates 90°)
  - Framed `GLOBAL-CFP-40X40` / `GLOBAL-CFP-32X40`
  - Metal `GLOBAL-DI-36X36` (sq) / `GLOBAL-DI-28X40` (portrait+landscape)
- **Prices (VAT-incl EUR)**: canvas 275 all; framed 325 sq / 275 p+l; metal 235 sq / 285 p+l.
- **Margin sanity-check (2026-06-15, live Prodigi `/quotes`, Standard shipping, EUR, cost = item+shipping; margin = retail − cost):** all products clear cost comfortably in US/UK/EU. Lowest margin ~€136 (metal square US). US is the priciest shipping lane; DE cheapest for canvas/framed; metal ships dearer to DE/US (different facility). **Serbia (test only) is the outlier** — that order's shipping was €128.94 (DHL Express Worldwide), margin only ~€53; ignore for launch pricing.

  | Product (retail) | US cost→margin | UK cost→margin | DE/EU cost→margin |
  |---|--:|--:|--:|
  | Canvas square (€275) | 100.60→+174 | 98.31→+177 | 90.95→+184 |
  | Canvas portrait/landscape (€275) | 100.60→+174 | 89.04→+186 | 78.95→+196 |
  | Framed square (€325) | 164.36→+161 | 137.70→+187 | 112.95→+212 |
  | Framed portrait/landscape (€275) | 129.90→+145 | 114.53→+161 | 96.95→+178 |
  | Metal square (€235) | 98.70→+136 | 74.21→+161 | 92.98→+143 |
  | Metal portrait/landscape (€285) | 102.32→+183 | 70.50→+215 | 91.24→+194 |

  **VAT caveat:** Prodigi costs are VAT-EXCLUSIVE (what we pay); retail is VAT-INCLUSIVE (what the customer pays). Once VAT-registered/remitting, net revenue ≈ `retail ÷ 1.2`, so subtract VAT before the "real" margin — still positive on every product (e.g. framed sq DE: €325→~€271 net − €112.95 = +€158). Re-pull quotes (`DEST=US,GB,DE node scripts/prodigi-discover.mjs <skus>`, fill required attrs) if Prodigi prices change.
- **Landscape orientation = image-aspect-driven (verified 2026-06-15).** Prodigi has NO orientation attribute and NO dedicated landscape SKU; each SKU is "Portrait / landscape" and orientation follows the supplied image's aspect ratio. So landscape variants reuse the portrait SKU and send the image **UPRIGHT/wide — `rotate` is false everywhere** (the old 90° rotate produced a portrait order with sideways content / wrong-side hardware). Thumbnail is generated from the upright crop. Confirmed end-to-end: a real order (`GLOBAL-CFP-32X40`, Color Black) shows upright + In production on Prodigi. Still worth a sandbox check per type (esp. framed hardware) before scaling.
- **Choosable attributes** (others auto): canvas `wrap` (ImageWrap default — **MirrorWrap removed**; Black/White solid edges), framed `color` (8 colours, key confirmed = `color`), metal `finish` (lustre default; gloss/matte). Generic `PrintOption`/`printOption(type)` in mobile; flows `checkout → prodigi_orders.attributes (JSON) → fulfill` (merged over catalog defaults).
- Mobile UX: studio "Order as wall art" (gated to US/UK/EU+RS via `isPrintRegionAllowed`) → wall-art screen (mockup + type/orientation + option selector + **3D canvas mockup** showing the wrap + **"Actual size" loupe** at true print scale) → crop → shipping address → review → Creem webview (`successPath: /print-success`) → **processing screen** → My Orders. Files: `lib/print/*`, `lib/screens/print/*`, `lib/api/print_api.dart`, `lib/state/print_providers.dart`, `lib/state/print_job_controller.dart`.
- Mockup background is the bundled wall photo `assets/wall.jpg`; `wallImageProvider` + `MockupPainter.wall` (cover-fit + dim/vignette/floor, procedural fallback). 3D canvas mockup: front shows inner region, right+bottom edges continue the image outward (true image-wrap, ~3 cm depth).

#### POD render = SERVER-SIDE, AFTER PAYMENT, NO TOKEN (changed this session)
- **Decision (user):** the print mosaic is rendered **server-side in `fulfill` after a verified payment** — NOT client-side, and **no render token is charged** (customer pays for the physical product, not a digital export). This also closes the free-render hole a client "skip token" flag would open.
- **checkout** now stores the *design* — `mosaicPlan` (slim plan JSON), `tileUrls` (JSON map), `baseUrl` — instead of a pre-rendered `mosaicUrl`. New `prodigi_orders` columns: `mosaic_plan`, `tile_urls`, `base_url`, plus `thumbnail_url`. Mobile `PrintApi.checkout(plan, tileUrls, baseUrl, …)`; `order_review` sends `studio.plan.toJson()` + `{id:blobUrl}` + `base.blobUrl` (no client render, no `maxResolutionProvider`).
- **fulfill** (`app/api/print/prodigi/fulfill/route.ts`): `verifyCreemPaid()` → `renderPrintAsset(order)` calls the **Cloud Run render service** (`RENDER_SERVICE_URL`/`_SECRET`, no token, no email) at `getMaxResolutionPrint()`, scaling plan output to that long side. The render output is a **private** blob → fetched with `Authorization: Bearer ${BLOB_READ_WRITE_TOKEN}` (a plain fetch 403s). Then a single sharp pipeline crops (normalised `cropRect`) + rotates landscape, uploads the print asset (private), and creates the Prodigi order. Requires Cloud Run enabled (errors clearly otherwise).
- **Print asset URL durability:** Prodigi pulls the asset async (and on reprints). The asset is served via `/api/print/preview/{token}`; `storePreviewToken(token, url, ttlMs)` now takes a TTL → print assets use **`PRINT_ASSET_EXPIRY_MS` = 30 days** (UI previews keep the 1h default). The preview route is **public** (token-gated, no auth/middleware) — that's why both Prodigi and `Image.network` can load it.
- **Thumbnail:** fulfill also makes a 600px thumbnail of the cropped print (private blob + 30-day token) → `thumbnail_url`. Shown in My Orders. Old orders (pre-deploy) have null → placeholder icon.
- **Emails (Resend):** `sendProdigiOrderConfirmationEmail` (order details) sent at end of fulfill; `sendProdigiShippedEmail` (with tracking) sent from the webhook on the **first** shipped transition. These are SEPARATE from the Printful `sendPrintOrderConfirmationEmail` (don't clobber). No digital "download ready" email for prints.
- **Webhook** (`/api/print/prodigi/webhook`): updates status + tracking; on first ship → `sendPrintShippedPush` **and** `sendProdigiShippedEmail`. Push data is typed (`{type:'print_shipped'}` vs render's `{type:'render_done'}`).

#### Resumable order processing (this session)
- Global `printJobControllerProvider` (`print_job_controller.dart`) runs `fulfill` and holds phase (idle/processing/done/failed) — survives leaving the screen. `OrderProcessingScreen` shows progress → success → **Retry** (idempotent, no re-charge). `order_review._pay` hands off to it + `pushAndRemoveUntil` to processing rooted at gallery.
- Processing screen back (AppBar + system, via `PopScope`) goes to **My Orders** while working (does NOT reset the job, so the pill keeps showing), or home when done.
- My Orders (`my_orders_screen.dart`): per-order **thumbnail**, option summary (`optionSummary`: "Image wrap"/"Black frame"/"Lustre finish"), price, status, **tappable + copyable tracking** (`url_launcher` + `Clipboard`), and **Resume/Retry** for paid-but-unsubmitted orders (`PrintOrderDto.isResumable`: `prodigiOrderId == null && status in {paid,uploading,submitted,failed}`). Orders endpoint now returns `prodigiOrderId`, `errorMessage`, `attributes` (parsed object), `thumbnailUrl`, `productKey`.
- **Push deep-link** (`push_service.dart` `_handleOpen`): routes by `message.data['type']` — `print_shipped` → My Orders (root navigator push), else → `/preview`.

#### Prefill (this session)
- Shipping form (`shipping_address_screen.dart`, now Consumer) prefills name + email from `authControllerProvider.user` (editable). Creem checkout passes `customer: { email: recipient.email }` to prefill the hosted page. Creem's `customer` object only supports `id`/`email` — **name/address can't be prefilled** into Creem (and don't need to be; shipping name/address flow only to Prodigi).

### POD — pending MANUAL steps (user)
1. Create **9 Creem products** at the prices above; set env `PRODIGI_CREEM_{CANVAS,FRAMED,METAL}_{SQUARE,PORTRAIT,LANDSCAPE}` = the Creem product_ids. (`CREEM_TEST_MODE=true` ⇒ test key + **test-mode** product ids; mismatch 404s.)
2. `PRODIGI_API_KEY` = **sandbox** key + `PRODIGI_SANDBOX=1`; `PRODIGI_CALLBACK_URL=https://studio.imagiastore.com/api/print/prodigi/webhook`; `PRODIGI_ALLOWED_COUNTRIES` (US,GB,RS,+EU). (`PRODIGI_API_KEY_LIVE` in `.env.local` is discovery-only.)
3. Ensure `RENDER_SERVICE_URL` + `RENDER_SERVICE_SECRET` set and **Cloud Run enabled** (fulfill renders there). `BLOB_READ_WRITE_TOKEN`, `RESEND_API_KEY`, `FROM_EMAIL`, `NEXT_PUBLIC_APP_URL` set.
4. **`pnpm db:push`** — adds `mosaic_plan`, `tile_urls`, `base_url`, `thumbnail_url`. (Without it, new orders fail at the fulfill UPDATE.)
5. Register the webhook in the Prodigi dashboard. Deploy foto-mozaik. **Rebuild the app** (new `url_launcher` plugin → pod install).
- A product is sellable only with **both** a SKU and a Creem product id (else checkout: "Product not available yet").
- Orders are retryable: `fulfill` is idempotent (guards on `prodigiOrderId`); a failed/paid order can be re-run (no re-charge) via My Orders → Resume or `POST /api/print/prodigi/fulfill {orderId}`. Earlier failed orders that predate the schema change lack `mosaic_plan` and can't be resumed — place a fresh order.

## App Store release readiness (in progress)

Full prioritized checklist was produced 2026-06-15. Three hard iOS blockers; progress:

**Blocker 1 — IAP for digital tokens (Guideline 3.1.1): CODE DONE (needs ASC products + Paid Apps agreement).** On iOS the token purchase now uses Apple IAP (consumables); **prints stay on Creem** (physical, exempt). On non-iOS the account screen keeps the Creem token flow.
- Client: `in_app_purchase` pkg; `lib/services/iap_service.dart` (`IapService` + `iapServiceProvider`/`iapApiProvider`) loads products, `buyConsumable`, and `verifyAndComplete` (verify server-side BEFORE `completePurchase`); `lib/api/iap_api.dart` (`verifyApple`). Account screen (iOS via `Platform.isIOS`) lists products with Apple's localized price, listens to `purchaseStream` in `initState` (catches interrupted txns), credits on purchased/restored, refreshes balance.
- Server: `lib/iap-apple.ts` (`APPLE_TOKEN_PRODUCTS` map, `verifyAndCreditApple` → Apple `verifyReceipt`, prod→sandbox fallback on 21007, idempotent credit), `POST /api/iap/apple/verify`. Idempotency via new `token_purchases.apple_transaction_id` (unique). Reuses the existing `userTokens` balance.
- **Product ids (must match ASC + the server map):** `com.imagiastore.studio.tokens.single` (1), `.tokens.pack5` (5), `.tokens.pack10` (10).
- NOTE: uses the (deprecated-but-working) `verifyReceipt`; eventual upgrade is the App Store Server API (StoreKit2 JWS) + Server Notifications v2 for refunds.
- MANUAL/PENDING: **Apple Paid Apps agreement + banking/tax (W-8BEN-E)** (gates all IAP testing); create the **3 consumable IAP products** in ASC at those ids/prices ($14.99/$49.99/$85.99); set env `APPLE_IAP_SHARED_SECRET` (App-Specific Shared Secret from ASC — recommended); `pnpm db:push` (adds `apple_transaction_id`); sandbox-test. Apple cut 15% (Small Business Program) / 30%; Apple sets price tiers and remits VAT.

**Blocker 2 — Sign in with Apple (Guideline 4.8): DONE (needs Apple-portal capability + rebuild).** Required because Google sign-in is offered. Native flow: `signInWithApple()` in `auth_controller.dart` (nonce → sha256 → `SignInWithApple.getAppleIDCredential`) → `AuthApi.signInApple` → server `POST /api/mobile/auth/apple` verifies the identity token with `jose` (JWKS, iss/aud=bundle id/exp/nonce), finds/creates/links user + session (mirrors the Google bridge), returns bearer. Apple button (iOS-only) on `sign_in_screen.dart`. Entitlement `com.apple.developer.applesignin` added to `Runner.entitlements`. Deps added: client `sign_in_with_apple`+`crypto`, server `jose`. MANUAL: enable "Sign In with Apple" on the App ID at developer.apple.com/account/resources/identifiers/list, refresh provisioning profile; optional env `APPLE_BUNDLE_ID`; rebuild + redeploy.

**Blocker 3 — In-app account deletion (Guideline 5.1.1(v)): DONE.** `DELETE /api/user` deletes the user row → cascades all data (sessions, accounts, orders, downloads, projects, tokens). Client: `UserApi.deleteAccount` → `AuthController.deleteAccount` (clears token, signs out; throws on failure) → red "Delete account" button + confirm dialog on the account screen.

**Privacy manifest: DONE (needs Xcode target add).** Created `ios/Runner/PrivacyInfo.xcprivacy` (no tracking; collected data types: email/name/phone/physical address/photos/userID/purchase history, all linked, App Functionality; required-reason APIs: file timestamp C617.1, user defaults CA92.1, system boot time 35F9.1, disk space E174.1). **MANUAL: add the file to the Runner target in Xcode** (drag into Runner group, check "Runner" target membership) or it won't be bundled. Keep its data types in sync with the App Store Connect App Privacy nutrition label.

**FREE-RENDER LAUNCH BRIDGE (active, 2026-06-15).** Because the Apple **Organization** account + Paid Apps agreement are pending (no IAP yet, and you can't sell digital goods via Creem/web links in-app — Guideline 3.1.1 / anti-steering), the decision is: **mobile (iOS + Android) mosaic generation is FREE; web keeps the token model; prints stay on Creem (physical, allowed).** This ships a fully compliant *free app* now; flip back to paid IAP once the org/agreement land.
- Client switch: **`AppConfig.freeRenders` (true)** — gates everything. `canRenderProvider` drops the token requirement; studio export/info text reworded (no "costs 1 token"/"Buy tokens"); account screen **hides the token-purchase section + balance chip** (shows "Mosaics are free to create"). IAP code is left intact, just gated off. `ApiClient` sends `X-Imagia-Client: mobile` + `X-Imagia-Mobile-Key: AppConfig.mobileRenderKey` while the bridge is on.
- Server: `/api/render` — `isFreeMobileRequest()` (header + `MOBILE_FREE_RENDER_SECRET` env) **skips the token check + consume** for mobile; web path unchanged. Soft gate (header spoofable) + **per-user daily cap `MOBILE_FREE_DAILY_CAP=15`** (counts `mosaic_downloads` today) to prevent abuse. Both the Cloud Run consume and the local `executeRender` (`chargeToken`) honor it; async/web job path still charges.
- **MANUAL:** set server env **`MOBILE_FREE_RENDER_SECRET`** = the app's `MOBILE_RENDER_KEY` (default `imagia-mobile-free-bridge-2026`, or override both via `--dart-define=MOBILE_RENDER_KEY=…`). Without the env set, mobile falls back to the paid token gate (free path off). Redeploy + rebuild.
- **To re-enable paid IAP later:** set `AppConfig.freeRenders = false`, rebuild (header stops, purchase UI returns), ensure ASC IAP products + Paid Apps agreement are live. One-line flip.

**Other release prep:** demo account + review notes and App Privacy nutrition-label answers are **drafted in `docs/APP_STORE_REVIEW.md`** (create the `review@imagiastore.com` account + fill the password). Still to do: paste them into ASC; public Privacy Policy URL; Info.plist usage strings reviewed for clarity (camera/photo add/photo read present); ASC metadata (screenshots, 1024 icon, age rating, category, support/marketing URLs); IAP products in ASC; export-compliance answer; verify production push from TestFlight (aps-environment is `development` in the file — distribution profile should swap to production, confirm).

## Other pending / nice-to-haves
- Audio for video: drop a royalty-free piano WAV at `assets/audio/piano.wav` (44100/stereo/16-bit) + pubspec entry (currently silent).
- Optional: credit-card calibration for exact real-size loupe; high-res tiled deep-zoom in the mosaic preview screen (left as-is, capped at maxSize=10000); use the wall photo behind the video too.
