import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
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

  @override
  bool get wantKeepAlive => widget.isTab; // Giữ state khi là tab

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
      if (widget.genre != null) params['genre'] = widget.genre;
      if (widget.country != null) params['country'] = widget.country;

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

  @override
  Widget build(BuildContext context) {
    super.build(context); // Cần thiết cho AutomaticKeepAliveClientMixin
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
}
