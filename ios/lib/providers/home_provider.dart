import 'package:flutter/foundation.dart';
import '../models/home_section.dart';
import '../models/movie.dart';
import '../services/home_service.dart';

class HomeProvider extends ChangeNotifier {
  final HomeService _homeService = HomeService();

  List<Movie> _heroMovies = [];
  List<HomeSection> _sections = [];
  bool _isLoading = false;
  String? _error;

  // Cache sections theo filter + timestamp
  final Map<String, _CacheEntry> _cache = {};
  static const _ttlMinutes = 5; // Cache hết hạn sau 5 phút

  List<Movie> get heroMovies => _heroMovies;
  List<HomeSection> get sections => _sections;
  bool get isLoading => _isLoading;
  String? get error => _error;

  String _currentFilter = 'all';
  String get currentFilter => _currentFilter;

  static const _allFilters = ['all', 'phim-bo', 'phim-le', 'the-loai'];

  bool _isCacheValid(String filter) {
    final entry = _cache[filter];
    if (entry == null) return false;
    final age = DateTime.now().difference(entry.timestamp).inMinutes;
    return age < _ttlMinutes;
  }

  Future<void> fetchHome({String filter = 'all', bool forceRefresh = false}) async {
    _currentFilter = filter;
    _error = null;

    // Nếu có cache hợp lệ → hiện ngay, refresh background nếu cần
    if (!forceRefresh && _isCacheValid(filter)) {
      _sections = _cache[filter]!.sections;
      notifyListeners();
      return;
    }

    // Có cache nhưng hết hạn → hiện cache, fetch background
    if (!forceRefresh && _cache.containsKey(filter)) {
      _sections = _cache[filter]!.sections;
      notifyListeners();
      _refreshInBackground(filter);
      return;
    }

    // Không có cache → hiện loading
    _isLoading = true;
    _sections = [];
    notifyListeners();

    try {
      final data = await _homeService.fetchHomeRaw(filter: filter);
      if (_currentFilter != filter) return;
      final heroes = data['heroMovies'] ?? [];
      if (heroes is List) {
        _heroMovies = heroes.map((e) => Movie.fromJson(e as Map<String, dynamic>)).toList();
      }
      final sections = data['sections'] ?? [];
      if (sections is List) {
        _sections = sections.map((e) => HomeSection.fromJson(e as Map<String, dynamic>)).toList();
        _cache[filter] = _CacheEntry(_sections, DateTime.now());
      }
    } catch (e) {
      if (_currentFilter != filter) return;
      _error = 'Có lỗi xảy ra. Vui lòng thử lại.';
    } finally {
      if (_currentFilter == filter) {
        _isLoading = false;
        notifyListeners();
      }
    }

    // Preload các filter còn lại trong background
    _preloadOtherFilters(filter);
  }

  /// Xóa toàn bộ cache (khi pull-to-refresh)
  void invalidateCache() {
    _cache.clear();
  }

  /// Preload các filter chưa cache
  void _preloadOtherFilters(String currentFilter) {
    for (final f in _allFilters) {
      if (f != currentFilter && !_isCacheValid(f)) {
        _fetchAndCache(f);
      }
    }
  }

  /// Fetch và cache filter (không update UI)
  Future<void> _fetchAndCache(String filter) async {
    try {
      final data = await _homeService.fetchHomeRaw(filter: filter);
      final sections = data['sections'] ?? [];
      if (sections is List) {
        _cache[filter] = _CacheEntry(
          sections.map((e) => HomeSection.fromJson(e as Map<String, dynamic>)).toList(),
          DateTime.now(),
        );
      }
    } catch (_) {
      // Ignore
    }
  }

  /// Refresh background — update cache + UI nếu đang ở filter này
  Future<void> _refreshInBackground(String filter) async {
    try {
      final data = await _homeService.fetchHomeRaw(filter: filter);
      if (_currentFilter != filter) return;
      final sections = data['sections'] ?? [];
      if (sections is List) {
        final parsed = sections.map((e) => HomeSection.fromJson(e as Map<String, dynamic>)).toList();
        _cache[filter] = _CacheEntry(parsed, DateTime.now());
        if (_currentFilter == filter) {
          _sections = parsed;
          notifyListeners();
        }
      }
    } catch (_) {
      // Ignore
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}

class _CacheEntry {
  final List<HomeSection> sections;
  final DateTime timestamp;
  _CacheEntry(this.sections, this.timestamp);
}
