import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:phimhay_app/config/app_config.dart';
import 'package:phimhay_app/config/responsive.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/models/movie.dart';
import 'package:phimhay_app/services/image_cache_manager.dart';
import 'package:phimhay_app/screens/movie_detail/movie_detail_screen.dart';
import 'package:phimhay_app/widgets/svg_icon.dart';
import 'package:phimhay_app/widgets/smart_link_ad.dart';

class SearchScreen extends StatefulWidget {
  final bool isTab;
  const SearchScreen({super.key, this.isTab = false});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final Dio _dio = Dio();
  Timer? _debounce;
  CancelToken? _pendingCancel;

  bool _isLoading = false;
  bool _isSearching = false;
  List<Movie> _results = [];
  bool _hasSearched = false;
  int _totalResults = 0;
  int _currentPage = 1;
  bool _hasMore = true;
  String? _errorMessage;

  // Search cache: key = query+filters, value = {results, total}
  final Map<String, List<Movie>> _cache = {};
  final Map<String, int> _cacheTotal = {};
  static const int _cacheMaxSize = 20;

  // Filters
  bool _showFilterPanel = false;
  String _country = '';
  String _genre = '';
  String _year = '';
  String _sortBy = '';
  String _filterType = '';
  String _serverType = '';

  // Filter data from API
  List<Map<String, dynamic>> _genres = [];
  List<Map<String, dynamic>> _countries = [];
  final List<int> _years = List.generate(21, (i) => DateTime.now().year - i);

  // Search history
  List<String> _searchHistory = [];
  bool _showHistory = false;
  bool _isLoadingHistory = false;
  static const int _historyMaxSize = 20;

  // Search suggestions (autocomplete)
  List<String> _suggestions = [];
  bool _showSuggestions = false;

  @override
  bool get wantKeepAlive => widget.isTab;

  bool get _hasActiveFilters => _country.isNotEmpty || _genre.isNotEmpty || _year.isNotEmpty || _sortBy.isNotEmpty || _filterType.isNotEmpty || _serverType.isNotEmpty;

  // ── Search History (server-side per account) ──
  static const String _historyKey = 'search_history';

  Future<void> _loadHistory() async {
    setState(() { _isLoadingHistory = true; });
    try {
      final res = await _dio.get('${AppConfig.apiUrl}/search_history.php', queryParameters: {'action': 'list'});
      if (res.data is Map && res.data['success'] == true) {
        final list = res.data['history'] as List<dynamic>? ?? [];
        setState(() { _searchHistory = list.cast<String>(); _isLoadingHistory = false; });
        return;
      }
    } catch (_) {}
    // Fallback to SharedPreferences if not logged in
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw != null) {
      setState(() { _searchHistory = (jsonDecode(raw) as List<dynamic>).cast<String>(); });
    }
    setState(() { _isLoadingHistory = false; });
  }

  Future<void> _saveToHistory(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    setState(() { _searchHistory.remove(q); _searchHistory.insert(0, q); });
    if (_searchHistory.length > _historyMaxSize) {
      _searchHistory = _searchHistory.sublist(0, _historyMaxSize);
    }
    // Save to server
    try {
      await _dio.post('${AppConfig.apiUrl}/search_history.php', data: {'action': 'save', 'keyword': q});
    } catch (_) {}
    // Also save to SharedPreferences as fallback
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_historyKey, jsonEncode(_searchHistory));
  }

  Future<void> _removeFromHistory(String query) async {
    setState(() { _searchHistory.remove(query); });
    try {
      await _dio.post('${AppConfig.apiUrl}/search_history.php', data: {'action': 'delete', 'keyword': query});
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_historyKey, jsonEncode(_searchHistory));
  }

  Future<void> _clearHistory() async {
    setState(() { _searchHistory.clear(); });
    try {
      await _dio.post('${AppConfig.apiUrl}/search_history.php', data: {'action': 'clear'});
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

  @override
  void initState() {
    super.initState();
    _fetchFilterData();
    _loadHistory();
    // ★ FIX: Tab mode → hiện lịch sử NGAY LẬP TỨC khi mở tab (giống YouTube)
    // Không cần chờ user tap vào search field
    if (widget.isTab) {
      _showHistory = true;
    }
    _searchFocus.addListener(() {
      if (mounted && _searchFocus.hasFocus) {
        // Bất kể có text hay không → đều hiện history
        setState(() { _showHistory = true; _results = []; _hasSearched = false; _showSuggestions = false; _suggestions = []; });
      }
    });
    // Tab: auto-focus search field để keyboard hiện ra ngay (giống YouTube)
    // Non-tab: cũng focus
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pendingCancel?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _fetchFilterData() async {
    try {
      final res = await _dio.get('${AppConfig.apiUrl}/danh_sach.php', queryParameters: {'filters_only': '1'});
      final data = res.data;
      if (data is Map) {
        setState(() {
          _genres = (data['genres'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          _countries = (data['countries'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        });
      }
    } catch (_) {}
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() { _showHistory = true; _results = []; _hasSearched = false; _errorMessage = null; _suggestions = []; _showSuggestions = false; });
      return;
    }
    setState(() { _showHistory = false; _showSuggestions = false; });
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (query.trim().isEmpty && !_hasActiveFilters) {
        setState(() { _results = []; _hasSearched = false; _errorMessage = null; _suggestions = []; _showSuggestions = false; });
        return;
      }
      // Lưu history SAU KHI search (không phải trước)
      _currentPage = 1;
      _hasMore = true;
      _fetchSuggestions(query.trim());
      _performSearch();
    });
  }

  // Fetch search suggestions (autocomplete)
  Future<void> _fetchSuggestions(String query) async {
    if (query.length < 2) {
      setState(() { _suggestions = []; _showSuggestions = false; });
      return;
    }
    try {
      final res = await _dio.get('${AppConfig.apiUrl}/search.php', queryParameters: {'q': query, 'type': 'phim', 'limit': 5});
      if (res.data is Map && res.data['success'] == true) {
        final movies = res.data['movies'] as List<dynamic>? ?? [];
        final suggestions = movies.map((m) => (m['name'] ?? '').toString()).where((s) => s.isNotEmpty).toList();
        if (mounted) {
          setState(() { _suggestions = suggestions; _showSuggestions = suggestions.isNotEmpty; });
        }
      }
    } catch (_) {}
  }

  String _cacheKey(String q) {
    return '$q|$_filterType|$_country|$_genre|$_year|$_sortBy|$_serverType';
  }

  Future<void> _performSearch({bool loadMore = false}) async {
    // Cancel request trước đó
    _pendingCancel?.cancel();
    _pendingCancel = CancelToken();

    final q = _searchCtrl.text.trim();
    final key = _cacheKey(q);

    // Check cache cho page 1
    if (!loadMore && _cache.containsKey(key)) {
      setState(() {
        _results = _cache[key]!;
        _totalResults = _cacheTotal[key] ?? 0;
        _hasSearched = true;
        _isLoading = false;
        _isSearching = false;
        _errorMessage = null;
      });
      return;
    }

    setState(() { _isLoading = true; _isSearching = true; _errorMessage = null; });

    try {
      final params = <String, dynamic>{
        'page': loadMore ? _currentPage + 1 : 1,
        'per_page': 24,
      };
      if (q.isNotEmpty) params['q'] = q;
      if (_country.isNotEmpty) params['country'] = _country;
      if (_genre.isNotEmpty) params['genre'] = _genre;
      if (_year.isNotEmpty) params['year'] = _year;
      if (_sortBy.isNotEmpty) params['sort'] = _sortBy;
      if (_filterType.isNotEmpty) params['type'] = _filterType;
      if (_serverType.isNotEmpty) params['server_type'] = _serverType;

      final res = await _dio.get('${AppConfig.apiUrl}/danh_sach.php', queryParameters: params, cancelToken: _pendingCancel);

      final data = res.data;
      if (data is Map) {
        final movies = (data['movies'] as List?) ?? [];
        final total = data['total'] ?? 0;
        final newResults = movies.map((e) => Movie.fromJson(e as Map<String, dynamic>)).toList();
        if (!mounted) return;
        setState(() {
          if (loadMore) {
            _results.addAll(newResults);
            _currentPage++;
          } else {
            _results = newResults;
            _currentPage = 1;
          }
          _totalResults = total;
          _hasSearched = true;
          _hasMore = _results.length < total;
          _isLoading = false;
          _isSearching = false;
          _errorMessage = null;
        });
        // Cache page 1
        if (!loadMore) {
          final cacheK = _cacheKey(q);
          _cache[cacheK] = newResults;
          _cacheTotal[cacheK] = total;
          if (_cache.length > _cacheMaxSize) {
            _cache.remove(_cache.keys.first);
            _cacheTotal.remove(_cacheTotal.keys.first);
          }
          // Lưu history SAU KHI search thành công
          if (q.isNotEmpty && newResults.isNotEmpty) {
            _saveToHistory(q);
          }
        }
      }
    } on DioException catch (e) {
      // Nếu bị cancel thì bỏ qua (search mới sẽ thay thế)
      if (e.type == DioExceptionType.cancel) return;
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isSearching = false;
        _errorMessage = 'Không thể kết nối. Kiểm tra mạng và thử lại.';
        if (!loadMore) { _results = []; _hasSearched = true; }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isSearching = false;
        _errorMessage = 'Có lỗi xảy ra. Thử lại sau.';
        if (!loadMore) { _results = []; _hasSearched = true; }
      });
    }
  }

  void _clearAllFilters() {
    setState(() {
      _country = '';
      _genre = '';
      _year = '';
      _sortBy = '';
      _filterType = '';
      _serverType = '';
    });
    _currentPage = 1;
    _hasMore = true;
    if (_searchCtrl.text.trim().isEmpty) {
      setState(() { _results = []; _hasSearched = false; });
    } else {
      _performSearch();
    }
  }

  void _removeFilter(String type) {
    setState(() {
      switch (type) {
        case 'country': _country = ''; break;
        case 'genre': _genre = ''; break;
        case 'year': _year = ''; break;
        case 'sort': _sortBy = ''; break;
        case 'type': _filterType = ''; break;
        case 'server_type': _serverType = ''; break;
      }
    });
    _currentPage = 1;
    _hasMore = true;
    if (_searchCtrl.text.trim().isEmpty && !_hasActiveFilters) {
      setState(() { _results = []; _hasSearched = false; });
    } else {
      _performSearch();
    }
  }

  void _applyFilters() {
    _currentPage = 1;
    _hasMore = true;
    _performSearch();
    // Giu panel mo de user thay ket qua, dong sau 300ms
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _showFilterPanel = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final body = Column(
      children: [
        const SizedBox(height: 12),
        // Search input
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Container(
            decoration: BoxDecoration(color: AppTheme.bgCard, borderRadius: BorderRadius.circular(999)),
            child: TextField(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              onChanged: _onSearchChanged,
              onSubmitted: (_) {
                _debounce?.cancel();
                _currentPage = 1;
                _hasMore = true;
                final q = _searchCtrl.text.trim();
                if (q.isNotEmpty) { _saveToHistory(q); setState(() { _showHistory = false; }); }
                _performSearch();
              },
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
              decoration: InputDecoration(
                hintText: 'Tim kiem phim yeu thich...',
                hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 16),
                prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.textMuted, size: 22),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.clear_rounded, color: AppTheme.textMuted, size: 20), onPressed: () {
                        _debounce?.cancel();
                        _pendingCancel?.cancel();
                        _searchCtrl.clear();
                        setState(() { _results = []; _hasSearched = false; _errorMessage = null; _isLoading = false; _showHistory = true; });
                        _searchFocus.requestFocus();
                      })
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ),

        // Filter toggle + active chips
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _filterToggleBtn(),
                  if (_hasActiveFilters) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _clearAllFilters,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(color: const Color(0x1AFF3B30), borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0x40FF3B30))),
                        child: const Text('Xoa bo loc', style: TextStyle(color: Color(0xFFFF3B30), fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ],
              ),
              if (_hasActiveFilters) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (_country.isNotEmpty) _activeChip(_countryLabel(_country), () => _removeFilter('country')),
                    if (_genre.isNotEmpty) _activeChip(_genreLabel(_genre), () => _removeFilter('genre')),
                    if (_serverType.isNotEmpty) _activeChip(_serverType == 'thuyetminh' ? 'Thuyết Minh' : 'Vietsub', () => _removeFilter('server_type')),
                    if (_year.isNotEmpty) _activeChip(_year, () => _removeFilter('year')),
                    if (_sortBy.isNotEmpty) _activeChip(_sortLabel(_sortBy), () => _removeFilter('sort')),
                    if (_filterType.isNotEmpty) _activeChip(_typeLabel(_filterType), () => _removeFilter('type')),
                  ],
                ),
              ],
            ],
          ),
        ),

        // Filter panel (expandable)
        if (_showFilterPanel) ...[
          const SizedBox(height: 8),
          _buildFilterPanel(),
        ],

        const SizedBox(height: 8),

        // Result count + error
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0x1AFF3B30), borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                const Icon(Icons.error_outline, color: Color(0xFFFF3B30), size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(_errorMessage!, style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 12))),
                GestureDetector(onTap: _performSearch, child: const Text('Thu lai', style: TextStyle(color: AppTheme.gold, fontSize: 12, fontWeight: FontWeight.w600))),
              ]),
            ),
          )
        else if (_hasSearched)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('$_totalResults ket qua', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            ),
          ),

        // Results
        Expanded(
          child: _isLoading && _results.isEmpty
              ? _buildSkeletonLoading()
              : _hasSearched && _results.isEmpty && _errorMessage == null
                  ? _buildEmptyState()
                  : _results.isNotEmpty
                      ? _buildResults()
                      : _buildInitialState(),
        ),
      ],
    );

    if (widget.isTab) return body;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.textPrimary), onPressed: () => Navigator.pop(context)),
        title: const Text('Tim kiem', style: TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
      ),
      body: body,
    );
  }

  Widget _filterToggleBtn() {
    return GestureDetector(
      onTap: () => setState(() => _showFilterPanel = !_showFilterPanel),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: _hasActiveFilters ? AppTheme.gold : AppTheme.bgCard,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: _hasActiveFilters ? AppTheme.gold : AppTheme.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_list_rounded, size: 16, color: _hasActiveFilters ? const Color(0xFF1A1100) : AppTheme.textSub),
            const SizedBox(width: 6),
            Text('Bo loc', style: TextStyle(
              color: _hasActiveFilters ? const Color(0xFF1A1100) : AppTheme.textSub,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            )),
          ],
        ),
      ),
    );
  }

  Widget _activeChip(String label, VoidCallback onRemove) {
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: AppTheme.gold.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.gold.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: AppTheme.gold, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: onRemove,
            child: Icon(Icons.close_rounded, size: 14, color: AppTheme.gold),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterPanel() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.55,
      ),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _filterRow('Loai phim:', [
              _filterOption('Tat ca', '', _filterType, (v) => setState(() => _filterType = '')),
              _filterOption('Phim bo', 'series', _filterType, (v) => setState(() => _filterType = 'series')),
              _filterOption('Phim le', 'single', _filterType, (v) => setState(() => _filterType = 'single')),
              _filterOption('Hoa tinh', 'hoathinh', _filterType, (v) => setState(() => _filterType = 'hoathinh')),
              _filterOption('TV Shows', 'tvshows', _filterType, (v) => setState(() => _filterType = 'tvshows')),
            ]),
            _filterRow('Quoc gia:', [
              _filterOption('Tat ca', '', _country, (v) => setState(() => _country = '')),
              ..._countries.map((c) => _filterOption(c['name'] ?? '', c['slug'] ?? '', _country, (v) => setState(() => _country = v))),
            ]),
            _filterRow('Server:', [
              _filterOption('Tat ca', '', _serverType, (v) => setState(() => _serverType = '')),
              _filterOption('Thuyet Minh', 'thuyetminh', _serverType, (v) => setState(() => _serverType = 'thuyetminh')),
              _filterOption('Vietsub', 'vietsub', _serverType, (v) => setState(() => _serverType = 'vietsub')),
            ]),
            _filterRow('The loai:', [
              _filterOption('Tat ca', '', _genre, (v) => setState(() => _genre = '')),
              ..._genres.map((g) => _filterOption(g['name'] ?? '', g['slug'] ?? '', _genre, (v) => setState(() => _genre = v))),
            ]),
            _filterRow('Nam:', [
              _filterOption('Tat ca', '', _year, (v) => setState(() => _year = '')),
              ..._years.map((y) => _filterOption('$y', '$y', _year, (v) => setState(() => _year = v))),
            ]),
            _filterRow('Sap xep:', [
              _filterOption('Mac dinh', '', _sortBy, (v) => setState(() => _sortBy = '')),
              _filterOption('Moi nhat', 'newest', _sortBy, (v) => setState(() => _sortBy = 'newest')),
              _filterOption('Diem cao', 'imdb', _sortBy, (v) => setState(() => _sortBy = 'imdb')),
              _filterOption('Xem nhieu', 'views', _sortBy, (v) => setState(() => _sortBy = 'views')),
            ]),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.gold,
                  foregroundColor: const Color(0xFF1A1100),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _applyFilters,
                child: const Text('Ap dung', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterRow(String label, List<Widget> options) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: AppTheme.textSub, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: options),
        ],
      ),
    );
  }

  Widget _filterOption(String label, String value, String currentValue, ValueChanged<String> onTap) {
    final isActive = value == currentValue;
    return GestureDetector(
      onTap: () => onTap(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? AppTheme.gold : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isActive ? AppTheme.gold : AppTheme.border),
        ),
        child: Text(label, style: TextStyle(
          color: isActive ? const Color(0xFF1A1100) : AppTheme.textSub,
          fontSize: 12,
          fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
        )),
      ),
    );
  }

  Widget _buildResults() {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification && notification.metrics.pixels >= notification.metrics.maxScrollExtent - 200 && _hasMore && !_isLoading) {
          _performSearch(loadMore: true);
        }
        return false;
      },
      child: GridView.builder(
        padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).padding.bottom + 80),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: Responsive.gridColumns(context), mainAxisSpacing: 12, crossAxisSpacing: 10, childAspectRatio: 0.55),
        itemCount: _results.length + (_hasMore ? 1 : 0),
        itemBuilder: (ctx, i) {
          if (i == _results.length) return const Center(child: CircularProgressIndicator(color: AppTheme.gold, strokeWidth: 2));
          final m = _results[i];
          return GestureDetector(
            onTap: () => SmartLinkAd.show(context, onComplete: () => Navigator.push(
              context,
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 400),
                reverseTransitionDuration: const Duration(milliseconds: 300),
                pageBuilder: (_, __, ___) => MovieDetailScreen(movie: m),
                transitionsBuilder: (_, animation, __, child) {
                  return FadeTransition(
                    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
                    child: child,
                  );
                },
              ),
            )),
            child: _buildMovieCard(m),
          );
        },
      ),
    );
  }

  Widget _buildMovieCard(Movie m) {
    final thumbUrl = m.thumbUrl ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: thumbUrl,
                  fit: BoxFit.cover,
                  cacheManager: AppImageCacheManager(),
                  cacheKey: '${m.slug}_${m.id}_${thumbUrl.hashCode}',
                  fadeInDuration: const Duration(milliseconds: 200),
                  fadeOutDuration: const Duration(milliseconds: 100),
                  placeholder: (_, __) => Container(color: AppTheme.bgCard),
                  errorWidget: (_, __, ___) => Container(color: AppTheme.bgCard, child: const Icon(Icons.movie, color: AppTheme.textMuted)),
                ),
                if ((m.quality ?? '').isNotEmpty)
                  Positioned(top: 6, right: 6, child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4)),
                    child: Text(m.quality!.toUpperCase(), style: const TextStyle(color: Color(0xFF1A1100), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                  )),
                if ((m.episodeCurrent ?? '').isNotEmpty)
                  Positioned(bottom: 6, left: 6, child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xD1121218),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0x14FFFFFF), width: 1),
                    ),
                    child: Text(m.episodeCurrent!, style: const TextStyle(color: Color(0xFFF1F5F9), fontSize: 9.5, fontWeight: FontWeight.w800)),
                  )),
                // TM badge — Thuyết Minh
                if (_isThuyetMinh(m.lang))
                  Positioned(top: 6, left: 6, child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5E6B8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('TM', style: TextStyle(color: Color(0xFF1A1100), fontSize: 9, fontWeight: FontWeight.w800)),
                  )),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(m.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w600, height: 1.3)),
        if (m.year != null || (m.originName ?? '').isNotEmpty)
          Text.rich(
            TextSpan(
              children: [
                if (m.year != null) TextSpan(text: '${m.year}', style: const TextStyle(color: Colors.white, fontSize: 10)),
                if (m.year != null && (m.originName ?? '').isNotEmpty) TextSpan(text: ' . ', style: TextStyle(color: AppTheme.textMuted, fontSize: 10)),
                if ((m.originName ?? '').isNotEmpty) TextSpan(text: m.originName!, style: TextStyle(color: AppTheme.textMuted, fontSize: 10)),
              ],
            ),
            maxLines: 1, overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  static bool _isThuyetMinh(String? raw) {
    if (raw == null) return false;
    final s = raw.toLowerCase();
    return s.contains('thuyết minh') || s.contains('lồng tiếng') || s.contains('tm') || s.contains('lt');
  }

  Widget _buildSkeletonLoading() {
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).padding.bottom + 80),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: Responsive.gridColumns(context), mainAxisSpacing: 12, crossAxisSpacing: 10, childAspectRatio: 0.55),
      itemCount: 9,
      itemBuilder: (ctx, i) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(color: AppTheme.bgCard),
              ),
            ),
            const SizedBox(height: 6),
            Container(height: 12, width: double.infinity, color: AppTheme.bgCard),
            const SizedBox(height: 4),
            Container(height: 10, width: 60, color: AppTheme.bgCard),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_off_rounded, size: 56, color: AppTheme.textMuted),
          const SizedBox(height: 12),
          Text('Khong tim thay phim nao phu hop', style: TextStyle(color: AppTheme.textSub, fontSize: 14)),
          const SizedBox(height: 4),
          Text('Thu voi tu khoa khac hoac bo loc khac', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildInitialState() {
    // Show loading indicator
    if (_isLoadingHistory) {
      return const Center(
        child: CircularProgressIndicator(color: AppTheme.accent, strokeWidth: 2),
      );
    }

    // Show search suggestions if available
    if (_showSuggestions && _suggestions.isNotEmpty) {
      return ListView.builder(
        itemCount: _suggestions.length,
        itemBuilder: (context, index) {
          final suggestion = _suggestions[index];
          return GestureDetector(
            onTap: () {
              _searchCtrl.text = suggestion;
              _searchCtrl.selection = TextSelection.fromPosition(TextPosition(offset: suggestion.length));
              setState(() { _showSuggestions = false; _showHistory = false; });
              _currentPage = 1;
              _hasMore = true;
              _performSearch();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  AppSvgIcon('clock.svg', size: 18, color: const Color(0xFF5C627A)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(suggestion, style: const TextStyle(color: Color(0xFFF0F0F0), fontSize: 15))),
                ],
              ),
            ),
          );
        },
      );
    }

    // Show search history if available and focused
    if (_showHistory && _searchHistory.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Lịch sử tìm kiếm', style: TextStyle(color: Color(0xFF9AA0B4), fontSize: 14, fontWeight: FontWeight.w700)),
                GestureDetector(
                  onTap: _clearHistory,
                  child: const Text('Xóa tất cả', style: TextStyle(color: Color(0xFFF5C518), fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          ..._searchHistory.map((q) => _buildHistoryItem(q)),
        ],
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_rounded, size: 64, color: AppTheme.textMuted.withValues(alpha: 0.3)),
          const SizedBox(height: 12),
          Text('Nhập từ khóa để tìm kiếm', style: TextStyle(color: AppTheme.textMuted, fontSize: 14)),
        ],
      ),
    );
  }

  Widget _buildHistoryItem(String query) {
    return GestureDetector(
      onTap: () {
        _searchCtrl.text = query;
        _searchCtrl.selection = TextSelection.fromPosition(TextPosition(offset: query.length));
        setState(() { _showHistory = false; });
        _currentPage = 1;
        _hasMore = true;
        _performSearch();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            AppSvgIcon('clock.svg', size: 18, color: const Color(0xFF5C627A)),
            const SizedBox(width: 12),
            Expanded(child: Text(query, style: const TextStyle(color: Color(0xFFF0F0F0), fontSize: 15))),
            GestureDetector(
              onTap: () { _removeFromHistory(query); },
              child: AppSvgIcon('trash.svg', size: 16, color: const Color(0xFF5C627A)),
            ),
          ],
        ),
      ),
    );
  }

  String _countryLabel(String slug) => _countries.firstWhere((c) => c['slug'] == slug, orElse: () => {'name': slug})['name'] ?? slug;
  String _genreLabel(String slug) => _genres.firstWhere((g) => g['slug'] == slug, orElse: () => {'name': slug})['name'] ?? slug;
  String _sortLabel(String s) => {'imdb': 'Diem cao', 'views': 'Xem nhieu', 'newest': 'Moi nhat'}[s] ?? s;
  String _typeLabel(String s) => {'series': 'Phim bo', 'single': 'Phim le', 'hoathinh': 'Hoa tinh', 'tvshows': 'TV Shows'}[s] ?? s;
}
