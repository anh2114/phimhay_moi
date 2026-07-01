import 'package:dio/dio.dart';
import '../services/api_client.dart';
import 'dart:io';

class ProfileService {
  final Dio _dio = ApiClient.dio;

  Future<Map<String, dynamic>> _parseResponse(Response res) async {
    final data = res.data;
    if (data is Map<String, dynamic>) return data;
    throw ApiException('Invalid response from server', statusCode: res.statusCode);
  }

  /// Get user profile + stats + tab data
  Future<Map<String, dynamic>> fetchProfile(String tab) async {
    final res = await _dio.get(
      '/profile.php',
      queryParameters: {'tab': tab},
    );
    return _parseResponse(res);
  }

  /// Update email/avatar
  Future<Map<String, dynamic>> updateProfile({
    required String email,
    String avatar = '',
  }) async {
    final res = await _dio.post(
      '/profile_update.php',
      data: FormData.fromMap({
        'action': 'update_profile',
        'email': email,
        'avatar': avatar,
      }),
    );
    return _parseResponse(res);
  }

  /// Upload avatar image file
  Future<String?> uploadAvatar(File imageFile) async {
    try {
      final formData = FormData.fromMap({
        'action': 'upload_avatar',
        'avatar': await MultipartFile.fromFile(imageFile.path, filename: 'avatar.jpg'),
      });
      final res = await _dio.post(
        '/profile_update.php',
        data: formData,
      );
      final data = await _parseResponse(res);
      if (data['success'] == true) {
        return data['url'] as String?;
      }
    } catch (_) {}
    return null;
  }

  /// Change password
  Future<Map<String, dynamic>> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final res = await _dio.post(
      '/profile_update.php',
      data: FormData.fromMap({
        'action': 'change_password',
        'old_password': oldPassword,
        'new_password': newPassword,
        'new_password2': newPassword,
      }),
    );
    return _parseResponse(res);
  }
}
