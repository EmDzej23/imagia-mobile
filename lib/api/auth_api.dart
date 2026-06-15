import 'package:dio/dio.dart';

import '../core/config.dart';

/// Authentication endpoints (better-auth). Sign-in returns a bearer token in
/// the body (`bearerToken()` plugin); we store it and send it as
/// `Authorization: Bearer`. Mirrors RN reference `lib/api/auth.ts`.
///
/// Uses a bare Dio (no auth interceptor) because these calls establish the
/// token rather than consume it.
class AuthApi {
  AuthApi({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: AppConfig.apiBaseUrl,
              headers: {'Origin': AppConfig.apiBaseUrl},
              validateStatus: (_) => true,
            ));

  final Dio _dio;

  /// Returns the session token on success, or throws [AuthException].
  Future<String> signInEmail(String email, String password) async {
    final res = await _post('/api/auth/sign-in/email', {
      'email': email,
      'password': password,
    }, 'Invalid email or password.');
    return _extractToken(res.data);
  }

  Future<String> signUpEmail(String name, String email, String password) async {
    await _post('/api/auth/sign-up/email', {
      'name': name,
      'email': email,
      'password': password,
    }, 'Could not create account.');
    // better-auth sign-up may not return a usable token; sign in to obtain one.
    return signInEmail(email, password);
  }

  Future<void> forgotPassword(String email) async {
    await _post('/api/auth/forget-password', {
      'email': email,
      'redirectTo': '${AppConfig.apiBaseUrl}/reset-password',
    }, 'Could not send reset email.');
  }

  /// The start URL to load in an auth webview for Google sign-in. On success the
  /// server redirects to [AppConfig.oauthRedirect]?token=...
  String googleStartUrl() {
    final redirect = Uri.encodeComponent(AppConfig.oauthRedirect);
    return '${AppConfig.apiBaseUrl}/api/mobile/auth/google-start?redirect=$redirect';
  }

  /// Extracts the token from the redirect URL captured by the auth webview.
  /// Verifies a native Apple identity token server-side and returns a session
  /// token. [fullName] is only available on the first authorization.
  Future<String> signInApple({
    required String identityToken,
    String? rawNonce,
    String? fullName,
  }) async {
    final res = await _post('/api/mobile/auth/apple', {
      'identityToken': identityToken,
      'rawNonce': ?rawNonce,
      'fullName': ?fullName,
    }, 'Apple sign-in failed.');
    return _extractToken(res.data);
  }

  String? tokenFromRedirect(Uri uri) {
    final fromQuery = uri.queryParameters['token'];
    if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
    final frag = uri.fragment;
    final idx = frag.indexOf('token=');
    if (idx >= 0) return frag.substring(idx + 6);
    return null;
  }

  Future<Response> _post(
      String path, Map<String, dynamic> body, String fallbackError) async {
    Response res;
    try {
      res = await _dio.post(path, data: body);
    } on DioException {
      throw const AuthException('Network error — check your connection.');
    }
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw AuthException(_errorMessage(res.data, fallbackError));
    }
    return res;
  }

  String _extractToken(dynamic data) {
    final token = (data is Map)
        ? (data['token'] ?? (data['data'] is Map ? data['data']['token'] : null))
        : null;
    if (token is String && token.isNotEmpty) return token;
    throw const AuthException('Authentication failed — no token received.');
  }

  String _errorMessage(dynamic data, String fallback) {
    if (data is Map) {
      final msg = data['error'] ?? data['message'];
      if (msg is String) return msg;
    }
    return fallback;
  }
}

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}
