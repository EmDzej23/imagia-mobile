# imagia-mobile — product context

Flutter (iOS + Android) client for **imagia / foto-mozaik**. It turns a photo into art. The backend is the **sibling Next.js app `foto-mozaik`** (production `studio.imagiastore.com`) — this app talks to it over HTTP; the heavy photo-mosaic render happens server-side (Cloud Run). Package id `com.imagiastore.studio`.

> **The most detailed handoff doc is `PROGRESS.md`** (architecture, conventions, push, POD/print, payments, video). This file is the higher-level map. Auto-loaded memory lives under `~/.claude/projects/-Users-marko-imagia-mobile/memory/` (flutter-port notes, API contract). NOTE: `PROGRESS.md`'s "Text Mosaic = web-only" line is stale — see Modes.

## Stack & architecture
- **Flutter/Dart**, **Riverpod** (`StudioController`/`StudioState` in `lib/state/`), **go_router**, **dio**. FCM push, Creem payments, Prodigi POD print.
- **The mosaic engine is a bit-exact Dart port of the web engine** (`lib/mosaic/*` mirrors foto-mozaik's `lib/mosaic/*`): `types.dart` (`MosaicSettings`, `MosaicMode = String`), `shared.dart` (`sanitizeSettings` + `validModes`), `analyze.dart` (integral image / preprocess), `mosaic_engine.dart` (`_runLayout`), `text_tiles.dart` [being removed]. Layout + preview run on-device (isolates); the final tile-mosaic render is **server-side** via `/api/render` (`lib/api/render_api.dart`, token-gated).
- **No shared code with web** — every feature is re-implemented in Dart. When a feature changes on web, port the behaviour, not the code.

## Rendering modes — two paradigms
`MosaicSettings.mosaicMode` (a `String`) selects the mode. `sanitizeSettings` in `shared.dart` has the authoritative `validModes` whitelist — **a new mode or settings field is silently dropped if not added there** (the #1 gotcha, same as web).

1. **Tile-matching (photo) modes** — `original`, `blocks`, `square`, `landscape`, `portrait`. Analyze → layout on-device → **server render** via Cloud Run (`/create/export`, tokens, `canRenderProvider`).
2. **Tile-less on-device renderers** — render the whole picture with a pure Dart function; preview and export use the same code; export saves straight to the gallery via `gal` (no server, no tokens):
   - `ancient` / `ancient-curved` — `lib/ancient/ancient_renderer.dart` (+ `ancient_voronoi.dart`); preview `lib/screens/create/ancient_preview.dart`; controller `renderAncientPng`, `newAncientLayout`, `ancientSeedNonce`; export `_onAncientExport` → `Gal.putImageBytes` (10k).
   - `wordart` — typographic portrait, **being ported from web** (`foto-mozaik/lib/wordart/`). Mirrors the ancient seams exactly (renderer + `wordart_preview.dart` + `wordartParamsFromState` + controller nonce/render/export + `wordart*` settings fields + `validModes`). See the port plan in memory.

**Removed / do NOT reintroduce:** the old **shapes** mode (never ported) and the old tile-based **text** mode (`lib/mosaic/text_tiles.dart`, `text*` settings, `_buildTextPanel`, `generateTextTiles`) — superseded by `wordart`. The shared phrase input state (word list / uppercase) is kept for word art.

## The tile-less mode pattern (mirror ANCIENT to add/edit one)
- **Renderer** (`lib/<mode>/*.dart`): an immutable `Params` value class (`==`/`hashCode` so the preview only rebuilds on real change), a pure `buildGeometry(rgba,…)`, a `CustomPainter`, and `render…Image(...) → Future<ui.Image>` used by BOTH preview and export.
- **Preview widget** (`lib/screens/create/<mode>_preview.dart`): samples `base.thumbnail` to RGBA once, debounces on `params`, rasterises to ONE static `ui.Image` shown via `RawImage(fit: contain)` (never re-paint 10k paths live). Plus a free `…ParamsFromState(StudioState)`.
- **Controller** (`lib/state/studio_controller.dart`): a `seedNonce` + `new…Layout()` + `render…Png({longSide}) → Future<Uint8List?>`. **`updateSettings()` must early-return the heavy `buildPlan()` isolate for tile-less modes** — add the new mode to that guard or it will run the tile layout pointlessly.
- **Settings** (`types.dart` + `shared.dart`): thread each field through ctor defaults, decls, `copyWith`, `fromJson`, `toJson` (6 places), and clamp/whitelist it in `sanitizeSettings`.
- **Studio screen** (`lib/screens/create/studio_screen.dart`): an `is<Mode>` bool gates a mode chip (`SegmentOption`), the preview swap, a `_build<Mode>Panel`, hiding the tile controls + tiles section, and a save action in the `bottomNavigationBar`.

## Video / export
- **Tile modes:** server render (tokens) → download.
- **Tile-less modes:** on-device PNG → `Gal.putImageBytes`.
- **Reel video** exists on-device: `lib/video/video_generator.dart` (`generateMosaicVideo`) draws 9:16 frames and feeds `flutter_quick_video_encoder`. Currently wired for the tile-mosaic plan; the word-art reel is a follow-up.

## Release
iOS marketing version is `pubspec.yaml` `version:` → `CFBundleShortVersionString` (`$(FLUTTER_BUILD_NAME)`); must exceed the last approved App Store version or the upload 409s.
