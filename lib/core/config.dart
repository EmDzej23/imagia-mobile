import 'dart:io';

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
  /// PER PLATFORM, deliberately:
  ///  - iOS is OFF the bridge — StoreKit IAP is live, so exports cost a token
  ///    exactly as they do on web, and the purchase tiles appear in Account.
  ///  - Android STAYS on it until Play Billing is set up. Turning it off there
  ///    would expose the Creem webview for a digital purchase, which breaches
  ///    Play's payments policy exactly as it would Apple's. Selling nothing in
  ///    the app is the compliant interim.
  ///
  /// NB `final`, not `const`: it reads [Platform] at startup.
  static final bool freeRenders = !Platform.isIOS;

  /// Shared secret identifying the mobile app to the server's free-render path
  /// (must equal the server env `MOBILE_FREE_RENDER_SECRET`). Soft gate — set
  /// your own value via `--dart-define=MOBILE_RENDER_KEY=...` and match it
  /// server-side. Only meaningful while [freeRenders] is true.
  static const String mobileRenderKey = String.fromEnvironment(
    'MOBILE_RENDER_KEY',
    defaultValue: 'imagia-mobile-free-bridge-2026',
  );
}
