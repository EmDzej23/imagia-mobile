import 'api_client.dart';

/// Authenticated user profile + token balance from GET /api/user.
class UserProfile {
  const UserProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.image,
    required this.isAdmin,
    required this.tokenBalance,
  });

  final String id;
  final String name;
  final String email;
  final String? image;
  final bool isAdmin;
  final int tokenBalance;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final user = (json['user'] as Map?) ?? const {};
    return UserProfile(
      id: user['id'] as String? ?? '',
      name: user['name'] as String? ?? '',
      email: user['email'] as String? ?? '',
      image: user['image'] as String?,
      isAdmin: user['isAdmin'] as bool? ?? false,
      tokenBalance: (json['tokenBalance'] as num?)?.toInt() ?? 0,
    );
  }
}

class UserApi {
  UserApi(this._client);
  final ApiClient _client;

  Future<ApiResult<UserProfile>> getUser() async {
    final res = await _client.get<Map<String, dynamic>>('/api/user');
    if (!res.isOk || res.data == null) {
      return ApiResult.fail(res.error ?? 'Failed to load profile.', res.status);
    }
    return ApiResult.ok(UserProfile.fromJson(res.data!), res.status);
  }

  /// Permanently deletes the signed-in user and all their data.
  Future<ApiResult<void>> deleteAccount() async {
    final res = await _client.delete<Map<String, dynamic>>('/api/user');
    if (!res.isOk) {
      return ApiResult.fail(res.error ?? 'Could not delete account.', res.status);
    }
    return ApiResult.ok(null, res.status);
  }
}
