import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import '../config/app_config.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;

  const ApiException(this.message, {this.statusCode});

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  static CookieJar? _cookieJar;
  static CookieJar get cookieJar => _cookieJar ??= CookieJar();

  static Future<CookieJar> _getCookieJar() async {
    if (_cookieJar != null) return _cookieJar!;
    final dir = await getApplicationDocumentsDirectory();
    final cookieDir = Directory('${dir.path}/cookies');
    if (!await cookieDir.exists()) await cookieDir.create(recursive: true);
    _cookieJar = PersistCookieJar(storage: FileStorage(cookieDir.path));
    return _cookieJar!;
  }

  static Dio? _dio;
  static Dio get dio => _dio!;

  // JWT tokens
  static String? _accessToken;
  static String? _refreshToken;
  static bool _isRefreshing = false;
  static final List<Function> _pendingRequests = [];

  static String? get accessToken => _accessToken;
  static String? get refreshToken => _refreshToken;
  static bool get isAuthenticated => _accessToken != null;

  static const _tokenKey = 'jwt_access_token';
  static const _refreshKey = 'jwt_refresh_token';

  static Future<void> init() async {
    final jar = await _getCookieJar();
    final platform = Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'unknown');

    // Load saved tokens
    await _loadTokens();

    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        'X-App-Client': 'phimhay-mobile',
        'X-App-Platform': platform,
      },
    ))..interceptors.addAll([
        _AuthInterceptor(),
        CookieManager(jar),
        _CloudflareInterceptor(),
      ]);
  }

  ApiClient._();

  // ============================================================
  // TOKEN MANAGEMENT
  // ============================================================

  /// Load tokens từ SharedPreferences — gọi TRƯỚC init() nếu cần
  static Future<void> loadTokens() async {
    await _loadTokens();
  }

  static Future<void> _loadTokens() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString(_tokenKey);
    _refreshToken = prefs.getString(_refreshKey);
  }

  static Future<void> setTokens({required String accessToken, required String refreshToken}) async {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, accessToken);
    await prefs.setString(_refreshKey, refreshToken);
  }

  static Future<void> clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_refreshKey);
  }

  static Future<bool> refreshAccessToken() async {
    if (_refreshToken == null) return false;
    if (_isRefreshing) return false;

    _isRefreshing = true;
    try {
      final dio = Dio(BaseOptions(
        baseUrl: AppConfig.apiUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ));

      final res = await dio.post('/mobile_auth.php', data: {
        'action': 'refresh',
        'refresh_token': _refreshToken,
      });

      final data = res.data;
      if (data['success'] == true) {
        await setTokens(
          accessToken: data['access_token'],
          refreshToken: data['refresh_token'],
        );
        return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      _isRefreshing = false;
    }
  }

  // ============================================================
  // API CALLS
  // ============================================================

  static Future<Response> get(String path, {Map<String, dynamic>? params}) async {
    try {
      final response = await dio.get(path, queryParameters: params);
      return response;
    } on DioException catch (e) {
      throw _handleError(e);
    }
  }

  static Future<Response> post(String path, {dynamic data}) async {
    try {
      final response = await dio.post(path, data: data);
      return response;
    } on DioException catch (e) {
      throw _handleError(e);
    }
  }

  static Future<Response> postAbsolute(String url, {dynamic data}) async {
    try {
      final response = await dio.post(url, data: data);
      return response;
    } on DioException catch (e) {
      throw _handleError(e);
    }
  }

  static ApiException _handleError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const ApiException('Kết nối bị timeout. Vui lòng thử lại.');
      case DioExceptionType.badResponse:
        return ApiException(
          (e.response?.data?['error'] ?? 'Lỗi máy chủ').toString(),
          statusCode: e.response?.statusCode,
        );
      case DioExceptionType.cancel:
        return const ApiException('Yêu cầu đã bị hủy.');
      default:
        return const ApiException('Không thể kết nối máy chủ. Vui lòng kiểm tra mạng.');
    }
  }
}

/// Interceptor: tự động thêm Authorization header + refresh token khi 401
class _AuthInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (ApiClient._accessToken != null) {
      // Gửi token qua nhiều cách để Cloudflare không strip
      options.headers['Authorization'] = 'Bearer ${ApiClient._accessToken}';
      options.headers['X-Auth-Token'] = ApiClient._accessToken;
      // Query parameter — Cloudflare KHÔNG strip query params
      options.queryParameters['auth_token'] = ApiClient._accessToken;
      print('[AuthInterceptor] Sending token to ${options.path}');
    } else {
      print('[AuthInterceptor] NO TOKEN for ${options.path}');
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    // Nếu 401 và có refresh token → thử refresh
    if (err.response?.statusCode == 401 && ApiClient._refreshToken != null) {
      final success = await ApiClient.refreshAccessToken();
      if (success) {
        // Retry request với token mới
        err.requestOptions.headers['Authorization'] = 'Bearer ${ApiClient._accessToken}';
        try {
          final dio = Dio();
          final response = await dio.fetch(err.requestOptions);
          handler.resolve(response);
          return;
        } catch (_) {}
      }
      // Refresh failed → clear tokens
      await ApiClient.clearTokens();
    }
    handler.next(err);
  }
}

/// Interceptor: detect Cloudflare challenge và retry
class _CloudflareInterceptor extends Interceptor {
  final int _maxRetries = 1;

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final contentType = response.headers.value('content-type') ?? '';

    if (contentType.contains('text/html') || contentType.contains('text/plain')) {
      final body = response.data?.toString() ?? '';

      if (body.contains('cf-challenge') ||
          body.contains('Checking your browser') ||
          body.contains('Just a moment') ||
          body.contains('Attention Required') ||
          body.contains('Ray ID')) {
        final retries = response.requestOptions.extra['cf_retries'] ?? 0;
        if (retries < _maxRetries) {
          response.requestOptions.extra['cf_retries'] = retries + 1;
          Future.delayed(const Duration(seconds: 2), () {
            final dio = Dio();
            dio.fetch(response.requestOptions).then(handler.resolve).catchError(handler.reject);
          });
          return;
        }
        handler.reject(DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
          message: 'Cloudflare protection active. Please try again.',
        ));
        return;
      }
    }

    if (response.statusCode == 200 && response.data is String) {
      final body = response.data as String;
      if (body.trimLeft().startsWith('<!') || body.trimLeft().startsWith('<html')) {
        final retries = response.requestOptions.extra['cf_retries'] ?? 0;
        if (retries < _maxRetries) {
          response.requestOptions.extra['cf_retries'] = retries + 1;
          Future.delayed(const Duration(seconds: 2), () {
            final dio = Dio();
            dio.fetch(response.requestOptions).then(handler.resolve).catchError(handler.reject);
          });
          return;
        }
        handler.reject(DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
          message: 'Server returned HTML instead of JSON',
        ));
        return;
      }
    }

    handler.next(response);
  }
}
