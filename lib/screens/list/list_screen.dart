import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:phimhay_app/config/app_config.dart';
import 'package:phimhay_app/services/api_client.dart';
import '../../config/theme.dart';
import '../../config/responsive.dart';
import '../../models/movie.dart';
import '../../widgets/movie_card.dart';
import '../movie_detail/movie_detail_screen.dart';

class ListScreen extends StatefulWidget {
  final String type;
  final String title;
  final String? genre;
  final String? country;
  final bool isTab;

  const ListScreen({
    super.key,
    this.type = 'phim-moi',
    this.title = 'Phim Mới',
    this.genre,
    this.country,
    this.isTab = false,
  });

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> with AutomaticKeepAliveClientMixin {
  final Dio _dio = ApiClient.dio;
  final ScrollController _scrollController = ScrollController();

  List<Movie> _movies = [];
  bool _isLoading = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;

  // Filters
  String _selectedGenre = '';
  String _selectedCountry = '';
  String _selectedYear = '';
  String _sortBy = '';
  bool _showFilters = false;
  List<Map<String, dynamic>> _genres = [];
  List<Map<String, dynamic>> _countries = [];
  final List<int> _years = List.generate(21, (i) => DateTime.now().year - i);

  bool get _hasActiveFilters => _selectedGenre.isNotEmpty || _selectedCountry.isNotEmpty || _selectedYear.isNotEmpty || _sortBy.isNotEmpty;

  @override
  bool get wantKeepAlive => widget.isTab;

  static const _typeOptions = [
    {'label': 'Phim Mới', 'type': 'phim-moi'},
    {'label': 'Phim Lẻ', 'type': 'phim-le'},
    {'label': 'Phim Bộ', 'type': 'phim-bo'},
    {'label': 'Hoạt Hình', 'type': 'hoat-hinh'},
    {'label': 'Chiếu Rạp', 'type': 'chieu-rap'},
    {'label': 'Top Xem', 'type': 'top-xem-nhieu'},
  ];

  late String _currentType;
  late String _currentTitle;

  @override
  void initState() {
    super.initState();
    _currentType = widget.type;
    _currentTitle = widget.title;
    if (widget.genre != null) _selectedGenre = widget.genre!;
    if (widget.country != null) _selectedCountry = widget.country!;
    _loadFilters();
    _loadMovies();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadFilters() async {
    try {
      final res = await _dio.get('${AppConfig.apiUrl}/danh_sach.php', queryParameters: {'filters_only': '1'});
      final data = res.data as Map<String, dynamic>;
      setState(() {
        _genres = (data['genres'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        _countries = (data['countries'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      });
    } catch (_) {}
  }

  Future<void> _loadMovies({bool reset = false}) async {
    if (_isLoading) return;
    if (reset) {
      _movies = [];
      _page = 1;
      _hasMore = true;
    }
    setState(() { _isLoading = true; _error = null; });

    try {
      final params = <String, dynamic>{
        'type': _currentType,
        'page': _page,
        'limit': 20,
      };
      if (_selectedGenre.isNotEmpty) params['genre'] = _selectedGenre;
      if (_selectedCountry.isNotEmpty) params['country'] = _selectedCountry;
      if (_selectedYear.isNotEmpty) params['year'] = _selectedYear;
      if (_sortBy.isNotEmpty) params['sort'] = _sortBy;

      final res = await _dio.get('/MovieList.php', queryParameters: params);
      final data = res.data as Map<String, dynamic>;
      final newMovies = (data['movies'] as List<dynamic>? ?? [])
          .map((e) => Movie.fromJson(e as Map<String, dynamic>))
          .toList();

      setState(() {
        _movies.addAll(newMovies);
        _hasMore = data['has_more'] == true;
        _isLoading = false;
        _page++;
      });
    } catch (e) {
      setState(() { _error = 'Không thể tải danh sách phim'; _isLoading = false; });
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _isLoading) return;
    await _loadMovies();
  }

  void _switchType(String type, String title) {
    if (_currentType == type) return;
    setState(() { _currentType = type; _currentTitle = title; });
    _loadMovies(reset: true);
  }

  String _genreLabel(String slug) => _genres.firstWhere((g) => g['slug'] == slug, orElse: () => {'name': slug})['name'] ?? slug;
  String _countryLabel(String slug) => _countries.firstWhere((c) => c['slug'] == slug, orElse: () => {'name': slug})['name'] ?? slug;
  String _sortLabel(String s) => {'imdb': 'Điểm cao', 'views': 'Xem nhiều', 'newest': 'Mới nhất'}[s] ?? s;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final body = Column(
      children: [
        // Type filter
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            physics: const BouncingScrollPhysics(),
            itemCount: _typeOptions.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final opt = _typeOptions[index];
              final isActive = _currentType == opt['type'];
              return GestureDetector(
                onTap: () => _switchType(opt['type']!, opt['label']!),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: isActive ? AppTheme.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isActive ? AppTheme.accent : AppTheme.border,
                      width: 1.5,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      opt['label']!,
                      style: TextStyle(
                        color: isActive ? const Color(0xFF1A1100) : AppTheme.textSub,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // Filter button + active chips
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => setState(() => _showFilters = !_showFilters),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _hasActiveFilters ? AppTheme.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _hasActiveFilters ? AppTheme.accent : AppTheme.border,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.filter_list_rounded, size: 16, color: _hasActiveFilters ? const Color(0xFF1A1100) : AppTheme.textSub),
                      const SizedBox(width: 4),
                      Text('Bộ lọc', style: TextStyle(color: _hasActiveFilters ? const Color(0xFF1A1100) : AppTheme.textSub, fontSize: 12, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (_selectedGenre.isNotEmpty)
                _activeChip(_genreLabel(_selectedGenre), () => setState(() { _selectedGenre = ''; _loadMovies(reset: true); })),
              if (_selectedCountry.isNotEmpty)
                _activeChip(_countryLabel(_selectedCountry), () => setState(() { _selectedCountry = ''; _loadMovies(reset: true); })),
              if (_selectedYear.isNotEmpty)
                _activeChip(_selectedYear, () => setState(() { _selectedYear = ''; _loadMovies(reset: true); })),
              if (_sortBy.isNotEmpty)
                _activeChip(_sortLabel(_sortBy), () => setState(() { _sortBy = ''; _loadMovies(reset: true); })),
            ],
          ),
        ),

        // Filter panel
        if (_showFilters)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2130),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _filterRow('Thể loại:', [
                  _filterOption('Tất cả', '', _selectedGenre, (v) => setState(() { _selectedGenre = v; _loadMovies(reset: true); })),
                  ..._genres.map((g) => _filterOption(g['name'] ?? '', g['slug'] ?? '', _selectedGenre, (v) => setState(() { _selectedGenre = v; _loadMovies(reset: true); }))),
                ]),
                const SizedBox(height: 8),
                _filterRow('Quốc gia:', [
                  _filterOption('Tất cả', '', _selectedCountry, (v) => setState(() { _selectedCountry = v; _loadMovies(reset: true); })),
                  ..._countries.map((c) => _filterOption(c['name'] ?? '', c['slug'] ?? '', _selectedCountry, (v) => setState(() { _selectedCountry = v; _loadMovies(reset: true); }))),
                ]),
                const SizedBox(height: 8),
                _filterRow('Năm:', [
                  _filterOption('Tất cả', '', _selectedYear, (v) => setState(() { _selectedYear = v; _loadMovies(reset: true); })),
                  ..._years.map((y) => _filterOption('$y', '$y', _selectedYear, (v) => setState(() { _selectedYear = v; _loadMovies(reset: true); }))),
                ]),
                const SizedBox(height: 8),
                _filterRow('Sắp xếp:', [
                  _filterOption('Mặc định', '', _sortBy, (v) => setState(() { _sortBy = v; _loadMovies(reset: true); })),
                  _filterOption('Mới nhất', 'newest', _sortBy, (v) => setState(() { _sortBy = v; _loadMovies(reset: true); })),
                  _filterOption('Điểm cao', 'imdb', _sortBy, (v) => setState(() { _sortBy = v; _loadMovies(reset: true); })),
                  _filterOption('Xem nhiều', 'views', _sortBy, (v) => setState(() { _sortBy = v; _loadMovies(reset: true); })),
                ]),
              ],
            ),
          ),

        // Grid
        Expanded(
          child: _error != null && _movies.isEmpty
              ? Center(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.error_outline, size: 48, color: AppTheme.textMuted),
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: AppTheme.textSub)),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => _loadMovies(reset: true),
                      child: const Text('Thử lại'),
                    ),
                  ]),
                )
              : RefreshIndicator(
                  onRefresh: () => _loadMovies(reset: true),
                  color: AppTheme.accent,
                  child: GridView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: Responsive.gridColumns(context),
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 14,
                      childAspectRatio: 132 / 248,
                    ),
                    itemCount: _movies.length + (_isLoading ? 3 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _movies.length) {
                        return Container(
                          decoration: BoxDecoration(
                            color: AppTheme.bgCard,
                            borderRadius: BorderRadius.circular(12),
                          ),
                        );
                      }
                      final movie = _movies[index];
                      return MovieCard(
                        movie: movie,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => MovieDetailScreen(movie: movie)),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );

    if (widget.isTab) return body;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _currentTitle,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
      body: body,
    );
  }

  Widget _activeChip(String label, VoidCallback onRemove) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onRemove,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppTheme.accentDim,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.accent.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(color: AppTheme.accent, fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              Icon(Icons.close, size: 12, color: AppTheme.accent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterRow(String label, List<Widget> options) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: options,
        ),
      ],
    );
  }

  Widget _filterOption(String label, String value, String currentValue, ValueChanged<String> onTap) {
    final isActive = value == currentValue;
    return GestureDetector(
      onTap: () => onTap(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isActive ? AppTheme.accent : const Color(0xFF252830),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive ? AppTheme.accent : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? const Color(0xFF1A1100) : Colors.white.withValues(alpha: 0.6),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
