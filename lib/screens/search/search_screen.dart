import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:phimhay_app/config/app_config.dart';
import 'package:phimhay_app/config/responsive.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/models/movie.dart';
import 'package:phimhay_app/screens/movie_detail/movie_detail_screen.dart';

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

  // Filter data from API
  List<Map<String, dynamic>> _genres = [];
  List<Map<String, dynamic>> _countries = [];
  final List<int> _years = List.generate(21, (i) => DateTime.now().year - i);

  @override
  bool get wantKeepAlive => widget.isTab;

  bool get _hasActiveFilters => _country.isNotEmpty || _genre.isNotEmpty || _year.isNotEmpty || _sortBy.isNotEmpty || _filterType.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _fetchFilterData();
    if (!widget.isTab) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
    }
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
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (query.trim().isEmpty && !_hasActiveFilters) {
        setState(() { _results = []; _hasSearched = false; _errorMessage = null; });
        return;
      }
      _currentPage = 1;
      _hasMore = true;
      _performSearch();
    });
  }

  String _cacheKey(String q) {
    return '$q|$_filterType|$_country|$_genre|$_year|$_sortBy';
  }

  Future<void> _performSearch({bool loadMore = false}) async {
    _pendingCancel?.cancel();
    _pendingCancel = CancelToken();
    if (_isLoading) return;

    final q = _searchCtrl.text.trim();
    final key = _cacheKey(q);

    // Check cache for page 1
    if (!loadMore && _cache.containsKey(key)) {
      setState(() {
        _results = _cache[key]!;
        _totalResults = _cacheTotal[key] ?? 0;
        _hasSearched = true;
        _isLoading = false;
        _isSearching = false;
      });
      return;
    }

    setState(() { _isLoading = true; _isSearching = true; _errorMessage = null; });

    try {
      final params = <String, dynamic>{
        'page': loadMore ? _currentPage + 1 : 1,
        'per_page': 24,
      };
      final q = _searchCtrl.text.trim();
      if (q.isNotEmpty) params['q'] = q;
      if (_country.isNotEmpty) params['country'] = _country;
      if (_genre.isNotEmpty) params['genre'] = _genre;
      if (_year.isNotEmpty) params['year'] = _year;
      if (_sortBy.isNotEmpty) params['sort'] = _sortBy;
      if (_filterType.isNotEmpty) params['type'] = _filterType;

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
        });
        // Store in cache (page 1 only)
        if (!loadMore) {
          final key = _cacheKey(q);
          _cache[key] = newResults;
          _cacheTotal[key] = total;
          if (_cache.length > _cacheMaxSize) {
            _cache.remove(_cache.keys.first);
            _cacheTotal.remove(_cacheTotal.keys.first);
          }
        }
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isSearching = false;
        _errorMessage = 'Loi ket noi. Kiem tra mang va thu lai.';
        if (!loadMore) { _results = []; _hasSearched = true; }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isSearching = false;
        _errorMessage = 'Co loi xay ra. Thu lai sau.';
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
              onSubmitted: (_) => _performSearch(),
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
              decoration: InputDecoration(
                hintText: 'Tim kiem phim yeu thich...',
                hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 16),
                prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.textMuted, size: 22),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.clear_rounded, color: AppTheme.textMuted, size: 20), onPressed: () { _searchCtrl.clear(); _onSearchChanged(''); _searchFocus.requestFocus(); })
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
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MovieDetailScreen(movie: m))),
            child: _buildMovieCard(m),
          );
        },
      ),
    );
  }

  Widget _buildMovieCard(Movie m) {
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
                  imageUrl: m.thumbUrl ?? '',
                  fit: BoxFit.cover,
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
                    decoration: BoxDecoration(color: AppTheme.gold, borderRadius: BorderRadius.circular(4)),
                    child: Text(m.episodeCurrent!, style: const TextStyle(color: Color(0xFF1A1100), fontSize: 9, fontWeight: FontWeight.w700)),
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_rounded, size: 64, color: AppTheme.textMuted.withValues(alpha: 0.3)),
          const SizedBox(height: 12),
          Text('Nhap tu khoa de tim kiem', style: TextStyle(color: AppTheme.textMuted, fontSize: 14)),
        ],
      ),
    );
  }

  String _countryLabel(String slug) => _countries.firstWhere((c) => c['slug'] == slug, orElse: () => {'name': slug})['name'] ?? slug;
  String _genreLabel(String slug) => _genres.firstWhere((g) => g['slug'] == slug, orElse: () => {'name': slug})['name'] ?? slug;
  String _sortLabel(String s) => {'imdb': 'Diem cao', 'views': 'Xem nhieu', 'newest': 'Moi nhat'}[s] ?? s;
  String _typeLabel(String s) => {'series': 'Phim bo', 'single': 'Phim le', 'hoathinh': 'Hoa tinh', 'tvshows': 'TV Shows'}[s] ?? s;
}
