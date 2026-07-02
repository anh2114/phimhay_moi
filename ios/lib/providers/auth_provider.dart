import 'package:flutter/foundation.dart';
import '../services/api_client.dart';

class AuthProvider extends ChangeNotifier {
  Map<String, dynamic>? _user;
  bool _loading = false;
  String? _error;

  Map<String, dynamic>? get user => _user;
  bool get isLoggedIn => _user != null && _user!['logged_in'] == true;
  bool get isLoading => _loading;
  String? get error => _error;

  AuthProvider() {
    _init();
  }

  Future<void> _init() async {
    await ApiClient.init();
    // Load user từ secure storage
    final savedUser = await ApiClient.loadUser();
    if (savedUser != null) {
      _user = savedUser;
      notifyListeners();
    }
  }

  Future<bool> login(String user, String pass) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final res = await ApiClient.post('/auth_simple.php', data: {
        'action': 'login',
        'username': user,
        'password': pass,
      });
      final d = res.data;
      if (d['success'] == true) {
        await ApiClient.saveToken(d['token'] ?? '');
        _user = Map<String, dynamic>.from(d['user'] ?? {});
        _user!['logged_in'] = true;
        await _save();
        _loading = false;
        notifyListeners();
        return true;
      }
      _error = d['error'] ?? 'Đăng nhập thất bại';
    } catch (_) {
      _error = 'Lỗi kết nối';
    }
    _loading = false;
    notifyListeners();
    return false;
  }

  Future<bool> register(String user, String email, String pass) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final res = await ApiClient.post('/auth_simple.php', data: {
        'action': 'register',
        'username': user,
        'email': email,
        'password': pass,
        'password_confirm': pass,
      });
      final d = res.data;
      if (d['success'] == true) {
        await ApiClient.saveToken(d['token'] ?? '');
        _user = Map<String, dynamic>.from(d['user'] ?? {});
        _user!['logged_in'] = true;
        await _save();
        _loading = false;
        notifyListeners();
        return true;
      }
      _error = d['error'] ?? 'Đăng ký thất bại';
    } catch (_) {
      _error = 'Lỗi kết nối';
    }
    _loading = false;
    notifyListeners();
    return false;
  }

  Future<void> logout() async {
    _user = null;
    await ApiClient.clearToken();
    await ApiClient.clearUser();
    notifyListeners();
  }

  Future<void> updateAvatar(String avatarUrl) async {
    if (_user == null) return;
    _user!['avatar'] = avatarUrl;
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    if (_user == null) return;
    await ApiClient.saveUser(_user!);
  }
}
