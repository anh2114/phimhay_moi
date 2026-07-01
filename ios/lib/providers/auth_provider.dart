import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../services/api_client.dart';

class AuthProvider extends ChangeNotifier {
  static const String _userKey = 'auth_user';

  Map<String, dynamic>? _user;
  bool _isLoading = false;
  String? _error;

  Map<String, dynamic>? get user => _user;
  bool get isLoggedIn => _user != null && (_user!['logged_in'] == true || _user!['user_id'] != null);
  bool get isLoading => _isLoading;
  String? get error => _error;

  AuthProvider() {
    _init();
  }

  Future<void> _init() async {
    await _loadFromStorage();
    // Nếu có token → check status với server
    if (_user != null && ApiClient.isAuthenticated) {
      await _checkAuthStatus();
    } else if (_user != null) {
      // Có user data nhưng không có token → có thể bị clear
      // Thử check status
      await _checkAuthStatus();
    }
  }

  Future<void> _loadFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final userJson = prefs.getString(_userKey);
    if (userJson != null) {
      try {
        _user = Map<String, dynamic>.from(jsonDecode(userJson));
        notifyListeners();
      } catch (_) {}
    }
  }

  /// Kiểm tra trạng thái login từ server (dùng JWT token)
  Future<void> _checkAuthStatus() async {
    try {
      final res = await ApiClient.get('/mobile_auth.php', params: {'action': 'status'});
      // mobile_auth.php expects POST
      final res2 = await ApiClient.post('/mobile_auth.php', data: {'action': 'status'});
      final data = res2.data;
      if (data is Map<String, dynamic> && data['logged_in'] == true) {
        _user = data;
        await _saveToStorage();
      } else {
        _user = null;
        await _clearStorage();
        await ApiClient.clearTokens();
      }
      notifyListeners();
    } catch (_) {
      // Offline — giữ nguyên state cũ từ SharedPreferences
    }
  }

  Future<bool> login(String usernameOrEmail, String password) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final res = await ApiClient.post('/mobile_auth.php', data: {
        'action': 'login',
        'username': usernameOrEmail,
        'password': password,
      });
      final data = res.data as Map<String, dynamic>;
      if (data['success'] == true) {
        // Lưu tokens
        await ApiClient.setTokens(
          accessToken: data['access_token'],
          refreshToken: data['refresh_token'],
        );

        // Lưu user data
        _user = data['user'] is Map
            ? Map<String, dynamic>.from(data['user'])
            : {'user_id': 0, 'username': usernameOrEmail, 'name': usernameOrEmail, 'role': 'user'};
        _user!['logged_in'] = true;
        await _saveToStorage();
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _error = data['error'] ?? 'Đăng nhập thất bại';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = 'Lỗi kết nối. Vui lòng kiểm tra mạng.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> register(String username, String email, String password) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final res = await ApiClient.post('/mobile_auth.php', data: {
        'action': 'register',
        'username': username,
        'email': email,
        'password': password,
        'password_confirm': password,
      });
      final data = res.data as Map<String, dynamic>;
      if (data['success'] == true) {
        // Lưu tokens
        await ApiClient.setTokens(
          accessToken: data['access_token'],
          refreshToken: data['refresh_token'],
        );

        _user = data['user'] is Map
            ? Map<String, dynamic>.from(data['user'])
            : {'user_id': 0, 'username': username, 'name': username, 'role': 'user'};
        _user!['logged_in'] = true;
        await _saveToStorage();
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _error = data['error'] ?? 'Đăng ký thất bại';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = 'Lỗi kết nối. Vui lòng kiểm tra mạng.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    try {
      await ApiClient.post('/mobile_auth.php', data: {
        'action': 'logout',
        'refresh_token': ApiClient.refreshToken,
      });
    } catch (_) {}
    _user = null;
    await _clearStorage();
    await ApiClient.clearTokens();
    notifyListeners();
  }

  Future<void> updateAvatar(String avatarUrl) async {
    if (_user == null) return;
    _user!['avatar'] = avatarUrl;
    notifyListeners();
    await _saveToStorage();
  }

  Future<void> _saveToStorage() async {
    if (_user == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(_user));
  }

  Future<void> _clearStorage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
