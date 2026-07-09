import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../config/app_config.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  const ApiException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

class ApiClient {
  static Dio? _dio;
  static Dio get dio => _dio!;

  static String? _token;
  static String? _refreshToken;
  static String? get token => _token;
  static String? get refreshToken => _refreshToken;
  static bool get isAuth => _token != null && _token!.isNotEmpty;

  // Secure storage thay SharedPreferences
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _keyToken = 'auth_token';
  static const _keyRefreshToken = 'auth_refresh_token';
  static const _keyUser = 'auth_user';

  // Race condition lock: chỉ 1 request refresh tại 1 thời điểm
  static Completer<bool>? _refreshCompleter;

  static Future<void> init() async {
    _token = await _storage.read(key: _keyToken);
    _refreshToken = await _storage.read(key: _keyRefreshToken);

    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
    ));

    _dio!.interceptors.add(InterceptorsWrapper(
      onRequest: (opts, handler) {
        if (_token != null && _token!.isNotEmpty) {
          // Gửi cả 2 cách: header + query param (backward compatible)
          opts.headers['Authorization'] = 'Bearer $_token';
          opts.queryParameters['auth_token'] = _token;
        }
        handler.next(opts);
      },
      onError: (err, handler) async {
        if (err.response?.statusCode == 401 && _token != null) {
          final refreshed = await _refresh();
          if (refreshed) {
            err.requestOptions.headers['Authorization'] = 'Bearer $_token';
            err.requestOptions.queryParameters['auth_token'] = _token;
            try {
              final res = await Dio().fetch(err.requestOptions);
              handler.resolve(res);
              return;
            } catch (_) {}
          }
        }
        handler.next(err);
      },
    ));
  }

  // Race condition-safe refresh
  static Future<bool> _refresh() async {
    // Không có refresh token → fail ngay
    if (_refreshToken == null || _refreshToken!.isEmpty) return false;

    // Nếu đang có refresh khác chạy → đợi kết quả của nó
    if (_refreshCompleter != null && !_refreshCompleter!.isCompleted) {
      return _refreshCompleter!.future;
    }

    _refreshCompleter = Completer<bool>();

    try {
      final res = await Dio(BaseOptions(baseUrl: AppConfig.apiUrl)).post(
        '/auth_simple.php',
        data: {'action': 'refresh', 'refresh_token': _refreshToken},
      );
      if (res.data['success'] == true) {
        _token = res.data['access_token'] ?? res.data['token'];
        _refreshToken = res.data['refresh_token'];
        await _storage.write(key: _keyToken, value: _token!);
        await _storage.write(key: _keyRefreshToken, value: _refreshToken!);
        _refreshCompleter!.complete(true);
        return true;
      }
    } catch (_) {}
    _refreshCompleter!.complete(false);
    _refreshCompleter = null;
    return false;
  }

  // Decode JWT và check expiry (client-side)
  static Map<String, dynamic>? decodeJwt(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      return jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // Check token còn hạn không (true = còn hạn)
  static bool isTokenValid() {
    if (_token == null || _token!.isEmpty) return false;
    final payload = decodeJwt(_token!);
    if (payload == null) return false;
    final exp = payload['exp'];
    if (exp == null) return false;
    final expiresAt = DateTime.fromMillisecondsSinceEpoch((exp as int) * 1000);
    return DateTime.now().isBefore(expiresAt);
  }

  // Check token sắp hết hạn (còn < 5 phút)
  static bool isTokenExpiringSoon({int withinMinutes = 5}) {
    if (_token == null || _token!.isEmpty) return true;
    final payload = decodeJwt(_token!);
    if (payload == null) return true;
    final exp = payload['exp'];
    if (exp == null) return true;
    final expiresAt = DateTime.fromMillisecondsSinceEpoch((exp as int) * 1000);
    final threshold = DateTime.now().add(Duration(minutes: withinMinutes));
    return threshold.isAfter(expiresAt);
  }

  // Refresh token chủ động nếu sắp hết hạn
  static Future<void> refreshIfNeeded() async {
    if (isTokenExpiringSoon()) {
      await _refresh();
    }
  }

  // Force refresh — dùng khi token đã hết hạn, trả về true nếu thành công
  static Future<bool> forceRefresh() async {
    if (_token == null || _token!.isEmpty) return false;
    return await _refresh();
  }

  // Lưu user data
  static Future<void> saveUser(Map<String, dynamic> user) async {
    await _storage.write(key: _keyUser, value: jsonEncode(user));
  }

  // Load user data
  static Future<Map<String, dynamic>?> loadUser() async {
    final raw = await _storage.read(key: _keyUser);
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  // Clear user data
  static Future<void> clearUser() async {
    await _storage.delete(key: _keyUser);
  }

  static Future<void> saveToken(String t) async {
    _token = t;
    await _storage.write(key: _keyToken, value: t);
  }

  static Future<void> saveRefreshToken(String t) async {
    _refreshToken = t;
    await _storage.write(key: _keyRefreshToken, value: t);
  }

  static Future<void> clearToken() async {
    _token = null;
    _refreshToken = null;
    await _storage.delete(key: _keyToken);
    await _storage.delete(key: _keyRefreshToken);
    _refreshCompleter = null;
  }

  static Future<Response> get(String path, {Map<String, dynamic>? params}) async {
    // Auto refresh trước khi request nếu sắp hết hạn
    await refreshIfNeeded();
    try {
      return await _dio!.get(path, queryParameters: params);
    } on DioException catch (e) {
      throw _err(e);
    }
  }

  static Future<Response> post(String path, {dynamic data}) async {
    await refreshIfNeeded();
    try {
      return await _dio!.post(path, data: data);
    } on DioException catch (e) {
      throw _err(e);
    }
  }

  static ApiException _err(DioException e) {
    if (e.type == DioExceptionType.badResponse) {
      return ApiException(
        (e.response?.data?['error'] ?? 'Lỗi server').toString(),
        statusCode: e.response?.statusCode,
      );
    }
    return ApiException('Lỗi kết nối. Thử lại sau.');
  }
}
