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

  /// Launch bridge: while Apple IAP isn't live (org account + Paid Apps pending),
  /// mosaic generation is FREE in the mobile apps and the in-app token-purchase
  /// UI is hidden. Web is unaffected. Flip to `false` to re-enable paid tokens.
  static const bool freeRenders = true;

  /// Shared secret identifying the mobile app to the server's free-render path
  /// (must equal the server env `MOBILE_FREE_RENDER_SECRET`). Soft gate — set
  /// your own value via `--dart-define=MOBILE_RENDER_KEY=...` and match it
  /// server-side. Only meaningful while [freeRenders] is true.
  static const String mobileRenderKey = String.fromEnvironment(
    'MOBILE_RENDER_KEY',
    defaultValue: 'imagia-mobile-free-bridge-2026',
  );
}
