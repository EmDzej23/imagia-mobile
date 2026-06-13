import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../core/config.dart';
import '../services/token_storage.dart';

/// Uniform result wrapper mirroring the RN reference `apiRequest` shape so call
/// sites can branch on `error` without try/catch everywhere.
class ApiResult<T> {
  const ApiResult.ok(this.data, this.status)
      : error = null;
  const ApiResult.fail(this.error, this.status) : data = null;

  final T? data;
  final String? error;
  final int status;

  bool get isOk => error == null;
}

/// Thin Dio wrapper that attaches the better-auth bearer token + Origin header
/// (the server checks Origin), normalizes errors, and surfaces 401s through an
/// [onUnauthorized] callback so the app can drop to the sign-in screen.
class ApiClient {
  ApiClient(this._tokens, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: AppConfig.apiBaseUrl,
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
              // We parse status ourselves; never throw on non-2xx.
              validateStatus: (_) => true,
            )) {
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        options.headers['Origin'] = AppConfig.apiBaseUrl;
        final token = await _tokens.read();
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
    ));
  }

  final Dio _dio;
  final TokenStorage _tokens;

  void Function()? onUnauthorized;

  Dio get raw => _dio;

  Future<ApiResult<T>> get<T>(String path,
      {Map<String, dynamic>? query}) {
    return _send<T>(() => _dio.get(path, queryParameters: query));
  }

  /// Fetches raw bytes (e.g. an image blob via /api/blob-proxy). Returns null
  /// on any non-2xx or error.
  Future<Uint8List?> getBytes(String path, {Map<String, dynamic>? query}) async {
    try {
      final res = await _dio.get<List<int>>(path,
          queryParameters: query,
          options: Options(responseType: ResponseType.bytes));
      final status = res.statusCode ?? 0;
      if (status < 200 || status >= 300 || res.data == null) return null;
      return Uint8List.fromList(res.data!);
    } on DioException {
      return null;
    }
  }

  Future<ApiResult<T>> post<T>(String path,
      {Object? body, Duration? receiveTimeout, Duration? sendTimeout}) {
    final options = (receiveTimeout != null || sendTimeout != null)
        ? Options(receiveTimeout: receiveTimeout, sendTimeout: sendTimeout)
        : null;
    return _send<T>(() => _dio.post(path, data: body, options: options));
  }

  Future<ApiResult<T>> put<T>(String path, {Object? body}) {
    return _send<T>(() => _dio.put(path, data: body));
  }

  Future<ApiResult<T>> patch<T>(String path, {Object? body}) {
    return _send<T>(() => _dio.patch(path, data: body));
  }

  Future<ApiResult<T>> delete<T>(String path, {Object? body}) {
    return _send<T>(() => _dio.delete(path, data: body));
  }

  Future<ApiResult<T>> _send<T>(Future<Response> Function() run) async {
    Response res;
    try {
      res = await run();
    } on DioException {
      return const ApiResult.fail('Network error — check your connection.', 0);
    }

    if (res.statusCode == 401) {
      await _tokens.clear();
      onUnauthorized?.call();
      return const ApiResult.fail('Session expired. Please sign in again.', 401);
    }

    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      return ApiResult.fail(_extractError(res.data, status), status);
    }
    return ApiResult.ok(res.data as T?, status);
  }

  String _extractError(dynamic data, int status) {
    if (data is Map) {
      final msg = data['error'] ?? data['message'];
      if (msg is String) return msg;
    }
    return 'Request failed ($status)';
  }
}
