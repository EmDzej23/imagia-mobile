
/// App-wide configuration. The API base URL can be overridden at build time
/// with `--dart-define=API_BASE_URL=...`; defaults to production (the same host
/// the web client and RN reference app use).
abstract final class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://studio.imagiastore.com',
  );

  /// Custom URI scheme used for OAuth deep-link redirects (Google sign-in).
  static const String deepLinkScheme = 'imagia';

  /// Redirect target handed to /api/mobile/auth/google-start.
  static const String oauthRedirect = '$deepLinkScheme://auth/callback';

  /// Launch bridge: mosaic generation is FREE and the in-app token-purchase UI is
  /// hidden. Web is unaffected.
  ///
  /// Both phones are now OFF the bridge: in-app purchase is live on each (StoreKit on
  /// iOS, Google Play Billing on Android), so an export costs a token exactly as on
  /// web, and the purchase tiles appear in Account. With this false the app stops
  /// sending the free-render key, so the server charges every render.
  ///
  /// NB `final`, not `const` (kept so a platform can be put back on the bridge).
  static final bool freeRenders = false;

  /// Shared secret identifying the mobile app to the server's free-render path
  /// (must equal the server env `MOBILE_FREE_RENDER_SECRET`). Soft gate — set
  /// your own value via `--dart-define=MOBILE_RENDER_KEY=...` and match it
  /// server-side. Only meaningful while [freeRenders] is true.
  static const String mobileRenderKey = String.fromEnvironment(
    'MOBILE_RENDER_KEY',
    defaultValue: 'imagia-mobile-free-bridge-2026',
  );
}
