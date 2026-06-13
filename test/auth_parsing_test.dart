import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/api/auth_api.dart';
import 'package:imagia_mobile/api/user_api.dart';

void main() {
  group('AuthApi.tokenFromRedirect', () {
    final api = AuthApi();

    test('extracts token from query parameter', () {
      final uri = Uri.parse('imagia://auth/callback?token=abc123');
      expect(api.tokenFromRedirect(uri), 'abc123');
    });

    test('extracts token from fragment', () {
      final uri = Uri.parse('imagia://auth/callback#token=xyz789');
      expect(api.tokenFromRedirect(uri), 'xyz789');
    });

    test('returns null when no token present', () {
      final uri = Uri.parse('imagia://auth/callback');
      expect(api.tokenFromRedirect(uri), isNull);
    });
  });

  group('UserProfile.fromJson', () {
    test('parses nested user object and token balance', () {
      final profile = UserProfile.fromJson({
        'user': {
          'id': 'u1',
          'name': 'Marko',
          'email': 'm@example.com',
          'image': null,
          'isAdmin': true,
        },
        'tokenBalance': 5,
      });
      expect(profile.id, 'u1');
      expect(profile.name, 'Marko');
      expect(profile.email, 'm@example.com');
      expect(profile.isAdmin, isTrue);
      expect(profile.tokenBalance, 5);
    });

    test('defaults gracefully on missing fields', () {
      final profile = UserProfile.fromJson({});
      expect(profile.id, '');
      expect(profile.isAdmin, isFalse);
      expect(profile.tokenBalance, 0);
    });
  });
}
