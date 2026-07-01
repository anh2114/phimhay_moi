import 'package:dio/dio.dart';
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
  static Dio? _dio;
  static Dio get dio => _dio!;

  static String? _accessToken;
  static String? _refreshToken;
  static String? get accessToken => _accessToken;
  static String? get refreshToken => _refreshToken;
  static bool get isAuthenticated => _accessToken != null && _accessToken!.isNotEmpty;

  static const _tokenKey = 'auth_token_raw';
  static const _refreshKey = 'auth_refresh_raw';

  static Future<void> init() async {
    await _loadTokens();
    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'X-App-Client': 'phimhay-mobile',
        'X-App-Platform': Platform.isIOS ? 'ios' : 'android',
      },
    ))..interceptors.addAll([
        _AuthInterceptor(),
        _CloudflareInterceptor(),
      ]);
  }

  static Future<void> loadTokens() async => _loadTokens();

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
    print('[ApiClient] Tokens saved. isAuthenticated=$isAuthenticated');
  }

  static Future<void> clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_refreshKey);
  }

  static Future<Response> get(String path, {Map<String, dynamic>? params}) async {
    try {
      return await _dio!.get(path, queryParameters: params);
    } on DioException catch (e) {
      throw _handleError(e);
    }
  }

  static Future<Response> post(String path, {dynamic data}) async {
    try {
      return await _dio!.post(path, data: data);
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

class _AuthInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (ApiClient._accessToken != null && ApiClient._accessToken!.isNotEmpty) {
      options.queryParameters['auth_token'] = ApiClient._accessToken;
      print('[Auth] Token → ${options.path}');
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode == 401 && ApiClient._refreshToken != null) {
      print('[Auth] 401 → trying refresh...');
      try {
        final dio = Dio(BaseOptions(baseUrl: AppConfig.apiUrl));
        final res = await dio.post('/mobile_auth.php', data: {
          'action': 'refresh',
          'refresh_token': ApiClient._refreshToken,
        });
        if (res.data['success'] == true) {
          await ApiClient.setTokens(
            accessToken: res.data['access_token'],
            refreshToken: res.data['refresh_token'],
          );
          err.requestOptions.queryParameters['auth_token'] = ApiClient._accessToken;
          final retry = await Dio().fetch(err.requestOptions);
          handler.resolve(retry);
          return;
        }
      } catch (_) {}
      await ApiClient.clearTokens();
    }
    handler.next(err);
  }
}

class _CloudflareInterceptor extends Interceptor {
  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final ct = response.headers.value('content-type') ?? '';
    if (ct.contains('text/html')) {
      final body = response.data?.toString() ?? '';
      if (body.contains('cf-challenge') || body.contains('Just a moment') || body.contains('Ray ID')) {
        final retries = response.requestOptions.extra['cf_retries'] ?? 0;
        if (retries < 1) {
          response.requestOptions.extra['cf_retries'] = retries + 1;
          Future.delayed(const Duration(seconds: 2), () {
            Dio().fetch(response.requestOptions).then(handler.resolve).catchError(handler.reject);
          });
          return;
        }
      }
    }
    handler.next(response);
  }
}
