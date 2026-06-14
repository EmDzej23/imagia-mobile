# Imagia Mobile — Progress & Handoff

Detailed running notes so work can resume after a context reset. Last updated: **2026-06-14**.

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
- Fix: `lib/api/features_api.dart` + `maxResolutionProvider` fetch `/api/features` `maxResolution` (currently **20000**). `RenderApi.render(outputLongSide:)` overrides the plan's output dims so the **long side = maxResolution**. Used by the export render (`render_controller`) and the print render (`order_review`). Admin settings: In-App Max = 20000, Print Max = 12000 (separate `getMaxResolutionPrint`, only used by the unused `/api/print/render`).

### Global render indicator
- `lib/widgets/render_indicator.dart` (`RenderIndicatorOverlay`) wrapped via `MaterialApp.builder`. Shows a tappable gradient pill on every screen while `renderControllerProvider.phase == rendering`; tap → `/create/export`. **Hidden on the export screen** (listens to `router.routeInformationProvider`). `RenderController.start()` no-ops if already rendering; studio Export button disabled + "Rendering…" while busy.

---

## Print-on-demand (Prodigi) — summary (full detail in `pod-prodigi-plan.md` memory)
- **Web already has a complete Printful POD** (`foto-mozaik/lib/print-products.ts`, `/api/print/*`). Decision: **leave Printful untouched**, build a **parallel Prodigi** stack under `/api/print/prodigi/*` + `prodigi_orders` table. Mobile uses Prodigi.
- Products (3 types × 3 orientations; poster excluded from app via `kAvailablePrintTypes`):
  - Canvas `GLOBAL-SLIMCAN-40X40` (sq) / `GLOBAL-SLIMCAN-32X40` (portrait+landscape, landscape rotates 90°)
  - Framed `GLOBAL-CFP-40X40` / `GLOBAL-CFP-32X40`
  - Metal `GLOBAL-DI-36X36` (sq) / `GLOBAL-DI-28X40` (portrait+landscape)
- **Prices (VAT-incl EUR)**: canvas 275 all; framed 325 sq / 275 p+l; metal 235 sq / 285 p+l.
- **Choosable attributes** (others auto): canvas `wrap` (ImageWrap default — **MirrorWrap removed**; Black/White solid edges), framed `color` (8 colours, key confirmed = `color`), metal `finish` (lustre default; gloss/matte). Generic `PrintOption`/`printOption(type)` in mobile; flows `checkout → prodigi_orders.attributes (JSON) → fulfill` (merged over catalog defaults).
- Mobile UX: studio "Order as wall art" (gated to US/UK/EU+RS via `isPrintRegionAllowed`) → wall-art screen (mockup + type/orientation + option selector + **3D canvas mockup** showing the wrap + **"Actual size" loupe** at true print scale) → crop → shipping address → review → Creem webview (`successPath: /print-success`) → fulfill → My Orders. Files: `lib/print/*`, `lib/screens/print/*`, `lib/api/print_api.dart`, `lib/state/print_providers.dart`.
- Render for print **reuses the regular `/api/render`** (not `/api/print/render`) → builds `/api/mosaic-image/{token}?maxSize=20000`; server `fulfill` crops with sharp + rotates landscape + creates the Prodigi order. **Print spends 1 render token** (user keeps digital copy).
- Mockup background is now the bundled wall photo `assets/wall.jpg` (converted from wall.avif); `wallImageProvider` + `MockupPainter.wall` (cover-fit, procedural fallback).
- 3D canvas mockup: front shows inner region, right+bottom edges continue the image outward (true image-wrap, ~3 cm depth).
- Shipped FCM push (`sendPrintShippedPush`) wired from `/api/print/prodigi/webhook`. Payment hardening: `verifyCreemPaid()` in fulfill (GET `/v1/checkouts/{id}`; rejects only on definitive unpaid).

### POD — pending MANUAL steps (user)
1. Create **9 Creem products** at the prices above; set env keys `PRODIGI_CREEM_{CANVAS,FRAMED,METAL}_{SQUARE,PORTRAIT,LANDSCAPE}` = the Creem product_ids.
2. Set `PRODIGI_API_KEY` = **sandbox** key (+ `PRODIGI_SANDBOX=1`) for test orders. (`PRODIGI_API_KEY_LIVE` is in `.env.local`, used only by `scripts/prodigi-discover.mjs` for quotes/discovery.) Also `PRODIGI_CALLBACK_URL=https://studio.imagiastore.com/api/print/prodigi/webhook`, `PRODIGI_ALLOWED_COUNTRIES` (US,GB,RS,+EU).
3. `pnpm db:push` in foto-mozaik (creates `prodigi_orders` incl. `attributes` column).
4. Register the webhook URL in the Prodigi dashboard. Deploy foto-mozaik. Rebuild the app.
- A product is only sellable with **both** a SKU and a Creem product id (else checkout returns "Product not available yet").

## Other pending / nice-to-haves
- Audio for video: drop a royalty-free piano WAV at `assets/audio/piano.wav` (44100/stereo/16-bit) + pubspec entry (currently silent).
- Optional: credit-card calibration for exact real-size loupe; high-res tiled deep-zoom in the mosaic preview screen (left as-is, capped at maxSize=10000); use the wall photo behind the video too.
