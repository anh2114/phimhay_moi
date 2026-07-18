import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/movie.dart';
import '../services/api_client.dart';

class FavoriteProvider extends ChangeNotifier {
  static const String _storageKey = 'favorites';

  List<Movie> _favorites = [];
  bool _isLoading = false;

  List<Movie> get favorites => _favorites;
  int get count => _favorites.length;
  bool get isLoading => _isLoading;

  FavoriteProvider() {
    _loadFromStorage();
  }

  Future<void> _loadFromStorage() async {
    _isLoading = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_storageKey);
      if (stored != null) {
        final List<dynamic> decoded = jsonDecode(stored);
        _favorites = decoded
            .map((e) => Movie.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      _favorites = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _saveToStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_favorites.map((e) => e.toJson()).toList());
    await prefs.setString(_storageKey, encoded);
  }

  bool isFavorite(int movieId) {
    return _favorites.any((m) => m.id == movieId);
  }

  Future<void> toggleFavorite(Movie movie) async {
    if (isFavorite(movie.id)) {
      await removeFavorite(movie.id);
    } else {
      await addFavorite(movie);
    }
  }

  Future<void> addFavorite(Movie movie) async {
    if (isFavorite(movie.id)) return;

    _favorites.add(movie);
    notifyListeners();
    await _saveToStorage();
    
    // Sync lên server
    try {
      await ApiClient.dio.post('/favorite.php', data: {'movie_id': movie.id});
    } catch (_) {}
  }

  Future<void> removeFavorite(int movieId) async {
    _favorites.removeWhere((m) => m.id == movieId);
    notifyListeners();
    await _saveToStorage();
    
    // Sync lên server
    try {
      await ApiClient.dio.post('/favorite.php', data: {'movie_id': movieId});
    } catch (_) {}
  }

  Future<void> clearAll() async {
    _favorites.clear();
    notifyListeners();
    await _saveToStorage();
  }

  /// Load favorites từ server (dùng khi mở profile)
  Future<void> loadFromServer() async {
    try {
      final res = await ApiClient.get('/profile.php', params: {'tab': 'favorites'});
      final data = res.data;
      if (data is Map && data['success'] == true) {
        final list = data['favorites'] as List<dynamic>? ?? [];
        _favorites = list.map((e) => Movie.fromJson(e as Map<String, dynamic>)).toList();
        await _saveToStorage();
        notifyListeners();
      }
    } catch (_) {}
  }
}
