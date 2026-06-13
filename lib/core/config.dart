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
}
