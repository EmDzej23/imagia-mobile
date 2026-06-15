import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../api/api_client.dart';
import '../api/auth_api.dart';
import '../api/checkout_api.dart';
import '../api/user_api.dart';
import '../core/config.dart';
import '../services/push_service.dart';
import '../services/token_storage.dart';

// ── Core service providers ──────────────────────────────────────────────────

final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(ref.watch(tokenStorageProvider));
  client.onUnauthorized = () {
    // Drop to signed-out on any 401; the router redirect handles navigation.
    ref.read(authControllerProvider.notifier).handleUnauthorized();
  };
  return client;
});

final authApiProvider = Provider<AuthApi>((ref) => AuthApi());

final userApiProvider =
    Provider<UserApi>((ref) => UserApi(ref.watch(apiClientProvider)));

final checkoutApiProvider =
    Provider<CheckoutApi>((ref) => CheckoutApi(ref.watch(apiClientProvider)));

// ── Auth state ──────────────────────────────────────────────────────────────

enum AuthStatus { unknown, signedOut, signedIn }

class AuthState {
  const AuthState({required this.status, this.user});

  final AuthStatus status;
  final UserProfile? user;

  const AuthState.unknown() : this(status: AuthStatus.unknown);
  const AuthState.signedOut() : this(status: AuthStatus.signedOut);
  AuthState.signedIn(UserProfile user)
      : this(status: AuthStatus.signedIn, user: user);

  bool get isSignedIn => status == AuthStatus.signedIn;
}

final authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    // Kick off the token bootstrap; state starts as unknown (splash/loading).
    _bootstrap();
    return const AuthState.unknown();
  }

  TokenStorage get _tokens => ref.read(tokenStorageProvider);
  AuthApi get _auth => ref.read(authApiProvider);
  UserApi get _user => ref.read(userApiProvider);

  Future<void> _bootstrap() async {
    // Run the real work concurrently with a minimum delay so the animated
    // splash gets to play before we navigate.
    final minSplash =
        Future<void>.delayed(const Duration(milliseconds: 3500));
    final token = await _tokens.read();
    if (token == null) {
      await minSplash;
      state = const AuthState.signedOut();
      return;
    }
    final res = await _user.getUser();
    await minSplash;
    if (res.isOk && res.data != null) {
      state = AuthState.signedIn(res.data!);
    } else {
      await _tokens.clear();
      state = const AuthState.signedOut();
    }
  }

  /// Loads the profile for the stored token; signs out if it's rejected.
  Future<void> _loadUser() async {
    final res = await _user.getUser();
    if (res.isOk && res.data != null) {
      state = AuthState.signedIn(res.data!);
      // Register this device for render-done push notifications.
      PushService.instance.registerToken(ref.read(apiClientProvider));
    } else {
      await _tokens.clear();
      state = const AuthState.signedOut();
    }
  }

  Future<void> refreshUser() => _loadUser();

  Future<void> signInEmail(String email, String password) async {
    final token = await _auth.signInEmail(email.trim(), password);
    await _tokens.write(token);
    await _loadUser();
  }

  Future<void> signUpEmail(String name, String email, String password) async {
    final token = await _auth.signUpEmail(name.trim(), email.trim(), password);
    await _tokens.write(token);
    await _loadUser();
  }

  /// Google sign-in via the system browser (ASWebAuthenticationSession on iOS,
  /// Chrome Custom Tabs on Android). Google blocks OAuth inside embedded
  /// WebViews, so this must NOT use a WebView. Captures the `imagia://` redirect
  /// and its `?token=`.
  Future<void> signInWithGoogle() async {
    final startUrl = _auth.googleStartUrl();
    final result = await FlutterWebAuth2.authenticate(
      url: startUrl,
      callbackUrlScheme: AppConfig.deepLinkScheme,
    );
    final token = _auth.tokenFromRedirect(Uri.parse(result));
    if (token == null || token.isEmpty) {
      throw const AuthException('No token received from Google sign-in.');
    }
    await _tokens.write(token);
    await _loadUser();
  }

  /// Native Sign in with Apple (iOS). Gets an Apple identity token on-device,
  /// has the server verify it, then stores the returned session token. The
  /// nonce is hashed (sha256) before being sent to Apple and re-checked server
  /// side against the token's `nonce` claim.
  Future<void> signInWithApple() async {
    final rawNonce = _generateNonce();
    final hashedNonce =
        sha256.convert(utf8.encode(rawNonce)).toString();

    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: const [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: hashedNonce,
    );

    final identityToken = credential.identityToken;
    if (identityToken == null || identityToken.isEmpty) {
      throw const AuthException('No Apple identity token received.');
    }
    // Name is only provided on the first authorization.
    final fullName = [credential.givenName, credential.familyName]
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .join(' ');

    final token = await _auth.signInApple(
      identityToken: identityToken,
      rawNonce: rawNonce,
      fullName: fullName.isEmpty ? null : fullName,
    );
    await _tokens.write(token);
    await _loadUser();
  }

  String _generateNonce([int length = 32]) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._';
    final rand = Random.secure();
    return List.generate(length, (_) => chars[rand.nextInt(chars.length)])
        .join();
  }

  Future<void> signOut() async {
    final token = await _tokens.read();
    if (token != null) {
      // Best-effort server-side revoke; ignore failures.
      try {
        await ref.read(apiClientProvider).post<dynamic>('/api/auth/sign-out');
      } catch (_) {}
    }
    await _tokens.clear();
    state = const AuthState.signedOut();
  }

  /// Permanently deletes the account + all its data, then signs out locally.
  /// Throws [AuthException] if the server delete fails (so the UI can surface it
  /// and NOT pretend the account was removed).
  Future<void> deleteAccount() async {
    final res = await _user.deleteAccount();
    if (!res.isOk) {
      throw AuthException(res.error ?? 'Could not delete account.');
    }
    await _tokens.clear();
    state = const AuthState.signedOut();
  }

  void handleUnauthorized() {
    _tokens.clear();
    state = const AuthState.signedOut();
  }
}
