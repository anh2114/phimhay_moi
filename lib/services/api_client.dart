import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';
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

  static Future<void> init() async {
    final jar = await _getCookieJar();
    final platform = Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'unknown');
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
        CookieManager(jar),
        _CloudflareInterceptor(),
      ]);
  }

  ApiClient._();

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

  /// POST với URL tuyệt đối (không prepend baseUrl)
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
      case DioExceptionType.connection:
        return const ApiException('Không thể kết nối máy chủ. Vui lòng kiểm tra mạng.');
      default:
        return const ApiException('Có lỗi xảy ra. Vui lòng thử lại.');
    }
  }
}

/// Interceptor: detect Cloudflare challenge page và xử lý gracefully
class _CloudflareInterceptor extends Interceptor {
  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final contentType = response.headers.value('content-type') ?? '';

    // Nếu response là HTML thay vì JSON → có thể là Cloudflare challenge
    if (contentType.contains('text/html') || contentType.contains('text/plain')) {
      final body = response.data?.toString() ?? '';

      // Detect Cloudflare challenge markers
      if (body.contains('cf-challenge') ||
          body.contains('Checking your browser') ||
          body.contains('Just a moment') ||
          body.contains('Attention Required') ||
          body.contains('Ray ID')) {
        // Throw lỗi rõ ràng thay vì để app crash khi parse JSON
        handler.reject(DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
          message: 'Cloudflare protection active. Please try again.',
        ));
        return;
      }
    }

    // Kiểm tra response có phải JSON hợp lệ không
    if (response.statusCode == 200 && response.data is String) {
      final body = response.data as String;
      if (body.trimLeft().startsWith('<!') || body.trimLeft().startsWith('<html')) {
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
