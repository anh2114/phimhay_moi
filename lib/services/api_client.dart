import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  static String? get token => _token;
  static bool get isAuth => _token != null && _token!.isNotEmpty;

  static const _key = 'auth_token';

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_key);

    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Accept': 'application/json', 'Content-Type': 'application/json'},
    ));

    _dio!.interceptors.add(InterceptorsWrapper(
      onRequest: (opts, handler) {
        if (_token != null) {
          opts.queryParameters['auth_token'] = _token;
        }
        handler.next(opts);
      },
      onError: (err, handler) async {
        if (err.response?.statusCode == 401 && _token != null) {
          final refreshed = await _refresh();
          if (refreshed) {
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

  static Future<bool> _refresh() async {
    try {
      final res = await Dio(BaseOptions(baseUrl: AppConfig.apiUrl)).post(
        '/auth_simple.php',
        data: {'action': 'refresh', 'token': _token},
      );
      if (res.data['success'] == true) {
        _token = res.data['token'];
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_key, _token!);
        return true;
      }
    } catch (_) {}
    return false;
  }

  static Future<void> saveToken(String t) async {
    _token = t;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, t);
  }

  static Future<void> clearToken() async {
    _token = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<Response> get(String path, {Map<String, dynamic>? params}) async {
    try { return await _dio!.get(path, queryParameters: params); }
    on DioException catch (e) { throw _err(e); }
  }

  static Future<Response> post(String path, {dynamic data}) async {
    try { return await _dio!.post(path, data: data); }
    on DioException catch (e) { throw _err(e); }
  }

  static ApiException _err(DioException e) {
    if (e.type == DioExceptionType.badResponse) {
      return ApiException((e.response?.data?['error'] ?? 'Lỗi server').toString(), statusCode: e.response?.statusCode);
    }
    return ApiException('Lỗi kết nối. Thử lại sau.');
  }
}
