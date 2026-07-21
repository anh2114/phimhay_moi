import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:phimhay_app/config/app_config.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/services/image_cache_manager.dart';
import 'package:phimhay_app/config/responsive.dart';
import 'package:phimhay_app/models/movie.dart';
import 'package:phimhay_app/providers/auth_provider.dart';
import 'package:phimhay_app/screens/auth/auth_screen.dart';
import 'package:phimhay_app/providers/favorite_provider.dart';
import 'package:phimhay_app/providers/reminder_provider.dart';
import 'package:phimhay_app/providers/watch_history_provider.dart';
import 'package:phimhay_app/screens/watch/watch_screen.dart';
import 'package:phimhay_app/screens/actors/actor_detail_screen.dart';
import 'package:phimhay_app/screens/notification/notification_screen.dart';
import 'package:phimhay_app/services/api_client.dart';
import 'package:phimhay_app/services/movie_service.dart';
import 'package:phimhay_app/widgets/movie_rail.dart';
import 'package:phimhay_app/widgets/shimmer_loading.dart';
import 'package:phimhay_app/widgets/header.dart';
import 'package:phimhay_app/widgets/bottom_nav.dart';
import 'package:phimhay_app/widgets/noise_overlay.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:phimhay_app/screens/home/home_screen.dart';
import 'package:phimhay_app/screens/watch_party/watch_party_screen.dart';
import 'package:phimhay_app/screens/actors/actors_list_screen.dart';
import 'package:phimhay_app/widgets/smart_link_ad.dart';
import 'package:phimhay_app/widgets/download_dialog.dart';


class MovieDetailScreen extends StatefulWidget {
  final int movieId;
  final String? slug;
  final Movie? movie;

  const MovieDetailScreen({
    super.key,
    this.movieId = 0,
    this.slug,
    this.movie,
  }) : assert(movieId > 0 || movie != null, 'Either movieId or movie must be provided');

  @override
  State<MovieDetailScreen> createState() => _MovieDetailScreenState();
}

class _MovieDetailScreenState extends State<MovieDetailScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final Dio _dio = Dio();
  int _navIndex = -1; // -1 = khong highlight tab nao (non-tab screen)
  bool _isLoading = true;
  String? _error;
  Map<String, dynamic>? _movieData;
  List<dynamic> _episodes = [];
  bool _isLoggedIn = false;
  List<dynamic> _servers = [];
  List<dynamic> _comments = [];
  List<Movie> _relatedMovies = [];
  List<Map<String, dynamic>> _actors = [];
  int _selectedServer = 0;
  final TextEditingController _commentController = TextEditingController();
  bool _isPostingComment = false;
  int _episodePage = 1; // Trang tập hiện tại (100 tập/trang)
  static const int _episodesPerPage = 100;
  bool _showInfoPanel = false;
  int _commentTab = 0; // 0: Bình luận, 1: Đánh giá
  bool _isSpoiler = false;
  List<dynamic> _ratings = [];
  double _avgRating = 0;
  int _ratingCount = 0;
  int _myRating = 0;
  List<String> _galleryImages = [];

  // Server grouping by source
  List<Map<String, dynamic>> _serverSources = []; // [{name: "Server#1", servers: [...]}]
  int _selectedSource = 0;
  int _selectedSourceServer = 0; // Server within selected source

  Map<String, dynamic> get _currentUser {
    return Provider.of<AuthProvider>(context, listen: false).user ?? {};
  }

  /// Chọn server mặc định thông minh:
  /// Ưu tiên server có nhiều tập nhất
  static int pickBestServer(List<dynamic> servers) {
    if (servers.isEmpty) return 0;
    int bestIdx = 0;
    int maxEps = 0;
    for (int i = 0; i < servers.length; i++) {
      final eps = servers[i]['episodes'] as List<dynamic>? ?? [];
      if (eps.length > maxEps) {
        maxEps = eps.length;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  /// Group servers by source (kkphim, ophim, etc.)
  void _groupServersBySource() {
    _serverSources = [];
    if (_servers.isEmpty) return;

    // Check if any server has a non-empty source field
    final hasSourceField = _servers.any((s) {
      final src = (s['source'] ?? '').toString().trim();
      return src.isNotEmpty;
    });

    // Helper: detect quality from source/server names
    String detectQuality(String source, List<dynamic> servers) {
      // Check source first
      if (source == 'kkphim') return 'FHD';
      if (source == 'ophim') return 'HD';
      if (source == 'manual') return '4K';
      // Fallback: check server names
      for (final s in servers) {
        final name = (s['server_name'] ?? '').toString().toLowerCase();
        if (name.contains('4k')) return '4K';
        if (name.contains('fhd') || name.contains('1080')) return 'FHD';
      }
      return 'HD';
    }

    if (!hasSourceField) {
      // No source field → each server is its own "source"
      int serverNum = 1;
      for (final server in _servers) {
        final sName = (server['server_name'] ?? 'Server $serverNum').toString();
        final epCount = (server['episodes'] as List<dynamic>?)?.length ?? 0;
        final quality = detectQuality('', [server]);
        _serverSources.add({
          'name': 'Server#$serverNum•$quality',
          'source': sName,
          'servers': [server],
          'totalEps': epCount,
        });
        serverNum++;
      }
    } else {
      // Has source field → group by source
      final Map<String, List<dynamic>> sourceGroups = {};
      for (final server in _servers) {
        final source = (server['source'] ?? '').toString().trim().toLowerCase();
        if (source.isEmpty) continue;
        if (!sourceGroups.containsKey(source)) {
          sourceGroups[source] = [];
        }
        sourceGroups[source]!.add(server);
      }

      int serverNum = 1;
      for (final entry in sourceGroups.entries) {
        final servers = entry.value;
        servers.sort((a, b) {
          final aEps = (a['episodes'] as List<dynamic>?)?.length ?? 0;
          final bEps = (b['episodes'] as List<dynamic>?)?.length ?? 0;
          return bEps.compareTo(aEps);
        });
        int totalEps = 0;
        for (final s in servers) {
          totalEps += (s['episodes'] as List<dynamic>?)?.length ?? 0;
        }
        final quality = detectQuality(entry.key, servers);
        _serverSources.add({
          'name': 'Server#$serverNum•$quality',
          'source': entry.key,
          'servers': servers,
          'totalEps': totalEps,
        });
        serverNum++;
      }
    }

    // Sort by total episodes (most first)
    _serverSources.sort((a, b) => (b['totalEps'] as int).compareTo(a['totalEps'] as int));

    if (_serverSources.isNotEmpty) {
      _selectedSource = 0;
      _selectedSourceServer = 0;
    }
  }

  // Watch progress — "Xem tiếp"
  final MovieService _movieService = MovieService();
  Map<String, dynamic>? _watchProgress; // {episode_id, ep_slug, server_idx, position, duration, ep_name}

  int get _currentMovieId => widget.movieId > 0 ? widget.movieId : (widget.movie?.id ?? (_movieData?['id'] as int? ?? 0));

  String _fixAvatarUrl(dynamic url) {
    if (url == null) return '';
    final s = url.toString();
    if (s.startsWith('http')) return s;
    return '${AppConfig.baseUrl}${s.startsWith('/') ? '' : '/'}$s';
  }

  bool get _isTrailerMovie {
    final ep = (_movieData?['episode_current'] ?? widget.movie?.episodeCurrent ?? '').toLowerCase();
    return ep.contains('trailer');
  }

  bool get _hasActiveEpisodes {
    if (_isTrailerMovie) return false;
    if (_servers.isNotEmpty) {
      final eps = _servers[_selectedServer]['episodes'] as List<dynamic>? ?? [];
      if (eps.isNotEmpty) return true;
    }
    return _episodes.isNotEmpty;
  }

  String? _extractYouTubeId(String url) {
    final patterns = [
      RegExp(r'youtube\.com/watch\?v=([a-zA-Z0-9_-]+)'),
      RegExp(r'youtu\.be/([a-zA-Z0-9_-]+)'),
      RegExp(r'youtube\.com/embed/([a-zA-Z0-9_-]+)'),
      RegExp(r'youtube\.com/v/([a-zA-Z0-9_-]+)'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  String? _trailerUrl() {
    final trailerRaw = _movieData?['trailer_url'] ?? _movieData?['trailer'] ?? _movieData?['trailer_embed'];
    if (trailerRaw is String && trailerRaw.trim().isNotEmpty) {
      return trailerRaw.trim();
    }
    return null;
  }

  void _playTrailer() {
    final slug = widget.movie?.slug ?? (_movieData?['slug'] ?? '');
    final title = widget.movie?.name ?? (_movieData?['name'] ?? '');
    final movieId = _currentMovieId;

    String? trailerUrl = _trailerUrl();

    if (trailerUrl == null) {
      if (_servers.isNotEmpty) {
        for (final server in _servers) {
          final eps = server['episodes'] as List<dynamic>? ?? [];
          if (eps.isNotEmpty) {
            final firstEp = eps[0];
            final embed = (firstEp['link_embed'] ?? '').toString().trim();
            final m3u8 = (firstEp['link_m3u8'] ?? '').toString().trim();
            trailerUrl = embed.isNotEmpty ? embed : m3u8;
            if (trailerUrl != null && trailerUrl.isNotEmpty) break;
          }
        }
      }
    }

    if (trailerUrl == null || trailerUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phim này chưa có trailer'), backgroundColor: Colors.orange, duration: Duration(seconds: 2)),
      );
      return;
    }

    final ytId = _extractYouTubeId(trailerUrl);
    if (ytId != null) {
      final ytUrl = Uri.parse('https://www.youtube.com/watch?v=$ytId');
      launchUrl(ytUrl, mode: LaunchMode.externalApplication);
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WatchScreen(
          movieId: movieId,
          episodeId: 1,
          serverIdx: 0,
          streamUrl: trailerUrl,
          movieSlug: slug,
          movieTitle: title,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
    _isLoggedIn = Provider.of<AuthProvider>(context, listen: false).isLoggedIn;
    _fetchMovieDetail();
    _fetchComments();

    // Lưu movie vào history
    if (widget.movie != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.read<WatchHistoryProvider>().setLastViewed(widget.movie!);
      });
    }
    // Load reminders from server
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      if (auth.isLoggedIn) {
        context.read<ReminderProvider>().fetchReminders();
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _fetchMovieDetail() async {
    // ignore: avoid_print
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final movieId = widget.movieId > 0 ? widget.movieId : (widget.movie?.id ?? 0);

    // Use passed-in movie data directly if available
    if (widget.movie != null) {
      _movieData = widget.movie!.toJson();
    }

    try {
      final slug = widget.slug ?? widget.movie?.slug ?? '';
      final endpoint = slug.isNotEmpty
          ? '${AppConfig.apiUrl}/movie_detail.php?slug=$slug'
          : '${AppConfig.apiUrl}/movie_detail.php?slug=${widget.movie?.slug ?? ''}';
      final response = await _dio.get(endpoint);
      final data = response.data is String
          ? jsonDecode(response.data) as Map<String, dynamic>
          : response.data as Map<String, dynamic>;

      if (data['movie'] != null) {
        _movieData = data['movie'] as Map<String, dynamic>;

        // servers + episodes nằm TRONG movie object (theo movie_detail.php)
        final movieObj = _movieData!;
        final rawServers = movieObj['servers'] as List<dynamic>? ?? [];
        final rawEpisodes = movieObj['episodes'] as List<dynamic>? ?? [];

        // Nếu servers trống, thử lấy từ top-level (backward compat)
        _servers  = rawServers.isNotEmpty  ? rawServers  : (data['servers']  as List<dynamic>? ?? []);
        _episodes = rawEpisodes.isNotEmpty ? rawEpisodes : (data['episodes'] as List<dynamic>? ?? []);
      } else {
        _servers  = data['servers']  as List<dynamic>? ?? [];
        _episodes = data['episodes'] as List<dynamic>? ?? [];
      }

      // Chọn server mặc định thông minh (nhiều tập nhất)
      if (_servers.isNotEmpty) {
        _selectedServer = pickBestServer(_servers);
        _groupServersBySource();
      }

      final related = data['related'] as List<dynamic>? ?? [];
      _relatedMovies = related
          .map((e) => Movie.fromJson(e as Map<String, dynamic>))
          .toList();
      _isLoading = false;

      _galleryImages = List.generate(10, (i) {
        final num = (i + 1).toString().padLeft(2, '0');
        return '${AppConfig.baseUrl}/thu_vien/$slug/$num.webp';
      });
      // ignore: avoid_print
      // Fetch gallery images from API
      _fetchGallery(slug);

      // Fetch actors data — SAU KHI API load thành công
      // ignore: avoid_print
      _fetchActors();
    } on DioException catch (e) {
      if (_movieData == null) {
        _error = 'Không thể tải thông tin phim';
      } else {
        _error = null;
      }
      _isLoading = false;
    }
    if (mounted) setState(() {});

    // Không check server health — tất cả nguồn đều sống (mobile HLS chạy được hết)

    // Fetch watch progress — "Xem tiếp"
    _fetchWatchProgress(movieId);
    _fetchRatings(movieId);
  }

  /// Fetch health status từ movie_episodes.php — merge vào _servers theo index
  Future<void> _fetchServerHealth(int movieId) async {
    if (movieId <= 0) return;
    try {
      final res = await _dio.get(
        '${AppConfig.apiUrl}/movie_episodes.php',
        queryParameters: {'movie_id': movieId},
      );
      final data = res.data as Map<String, dynamic>;
      final rawServers = (data['servers'] as List<dynamic>?)
              ?.cast<Map<String, dynamic>>() ?? [];

      if (mounted && rawServers.isNotEmpty && _servers.isNotEmpty) {
        setState(() {});
      }
    } catch (_) {
      // ignore — health là bonus, không ảnh hưởng chức năng chính
    }
  }

  void _onNavSelected(int index) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => HomeScreen(initialIndex: index)),
    );
  }

  /// Tạo room xem chung trực tiếp từ phim chi tiết
  Future<void> _createWatchParty() async {
    final movieId = widget.movieId > 0 ? widget.movieId : (widget.movie?.id ?? (_movieData?['id'] as int? ?? 0));
    if (movieId <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không tìm thấy phim'), backgroundColor: Colors.redAccent),
      );
      return;
    }

    // Lấy episode đầu tiên (nếu có)
    dynamic firstEp;
    if (_servers.isNotEmpty) {
      final eps = _servers[_selectedServer]['episodes'] as List<dynamic>? ?? [];
      if (eps.isNotEmpty) firstEp = eps[0];
    }
    final epId = firstEp?['id'] ?? 1;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator(color: AppTheme.accent)),
    );

    try {
      final res = await ApiClient.post(
        '/watch_party.php',
        data: FormData.fromMap({
          'action': 'create_room',
          'movie_id': movieId,
          'episode_id': epId,
        }),
      );
      if (mounted) Navigator.pop(context);

      final data = res.data;
      if (data['success'] == true && data['room_code'] != null) {
        final roomCode = data['room_code'];
        if (mounted) {
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(backgroundColor: AppTheme.bg, title: const Text('Phòng xem chung', style: TextStyle(fontSize: 16)), elevation: 0),
              body: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri('${AppConfig.baseUrl}/phong-xem.php?code=$roomCode')),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  mediaPlaybackRequiresUserGesture: false,
                  allowsInlineMediaPlayback: true,
                  mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                  supportZoom: false,
                  useWideViewPort: true,
                  loadWithOverviewMode: true,
                ),
                onPermissionRequest: (controller, request) async {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
              ),
            ),
          ));
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(data['error'] ?? 'Không thể tạo phòng'), backgroundColor: Colors.redAccent),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lỗi kết nối'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  /// Fetch watch progress từ server — hiển thị banner "Tiếp tục xem"
  Future<void> _fetchWatchProgress(int movieId) async {
    if (movieId <= 0) return;
    try {
      final progress = await _movieService.getWatchProgress(movieId);
      if (progress != null && mounted) {
        final epSlug = (progress['ep_slug'] as String?) ?? '';
        final epId = progress['episode_id'];
        // Hiển thị nếu có episode (id hoặc slug) — không cần pos >= 15
        if (epSlug.isNotEmpty || (epId != null && epId > 0)) {
          setState(() => _watchProgress = progress);
        }
      }
    } catch (_) {
      // Ignore — progress là bonus, không ảnh hưởng chính
    }
  }

  /// Format giây → chuỗi thời gian (giống web formatWatchPosition)
  String _formatPosition(int seconds) {
    if (seconds < 1) return '00:00';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Banner "Tiếp tục xem" — giống web phim.php watch-resume-banner
  Widget _buildResumeBanner(Movie movie) {
    final progress = _watchProgress!;
    final rawEpName = (progress['ep_name'] as String?) ?? '';
    final epName = rawEpName.replaceAll(RegExp(r'^[Tt]ậ?p?\s*', caseSensitive: false), '').trim();
    final position = (progress['position'] as int?) ?? 0;
    final duration = (progress['duration'] as int?) ?? 0;
    final serverIdx = (progress['server_idx'] as int?) ?? 0;

    int percent = 0;
    if (duration > 0) {
      percent = (position / duration * 100).round().clamp(0, 100);
    }

    final movieId = widget.movieId > 0 ? widget.movieId : (widget.movie?.id ?? (_movieData?['id'] as int? ?? 0));
    final posStr = _formatPosition(position);
    final durStr = _formatPosition(duration);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0x26F5921E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x73F5921E)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _resumeWatch(movieId, serverIdx),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                // Spinner icon
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    value: percent > 0 ? percent / 100 : null,
                    color: const Color(0xFFF5921E),
                    backgroundColor: const Color(0xFFF5921E).withValues(alpha: 0.2),
                  ),
                ),
                const SizedBox(width: 12),
                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Tiếp tục xem',
                        style: TextStyle(color: Color(0xFFF5921E), fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${epName.isNotEmpty ? 'Tập $epName' : 'Phim'}  •  $posStr / $durStr',
                        style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Button
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5921E),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Xem tiếp',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Nhảy đến đúng tập + server + vị trí khi nhấn "Xem tiếp"
  void _resumeWatch(int movieId, int savedServerIdx) {
    final progress = _watchProgress!;
    final savedEpId = progress['episode_id'];
    final savedEpSlug = (progress['ep_slug'] as String?) ?? '';
    final slug = widget.movie?.slug ?? (_movieData?['slug'] ?? '');
    final title = widget.movie?.name ?? (_movieData?['name'] ?? '');

    // Tìm episode từ danh sách đã fetch
    dynamic targetEp;
    if (_servers.isNotEmpty) {
      // Ưu tiên server đã lưu
      final serverIdx = savedServerIdx < _servers.length ? savedServerIdx : 0;
      final eps = _servers[serverIdx]['episodes'] as List<dynamic>? ?? [];
      for (final ep in eps) {
        final epSlug = (ep['ep_slug'] ?? ep['slug'] ?? '').toString();
        final epId = ep['id'];
        if (epSlug == savedEpSlug || epId == savedEpId) {
          targetEp = ep;
          break;
        }
      }
      // Fallback: tìm ở tất cả servers
      if (targetEp == null) {
        for (final server in _servers) {
          final eps = server['episodes'] as List<dynamic>? ?? [];
          for (final ep in eps) {
            final epSlug = (ep['ep_slug'] ?? ep['slug'] ?? '').toString();
            final epId = ep['id'];
            if (epSlug == savedEpSlug || epId == savedEpId) {
              targetEp = ep;
              break;
            }
          }
          if (targetEp != null) break;
        }
      }
    }

    // Fallback cuối: dùng URL trang web
    String url = '';
    if (targetEp != null) {
      final embed = (targetEp['link_embed'] ?? '').toString().trim();
      final m3u8 = (targetEp['link_m3u8'] ?? '').toString().trim();
      url = embed.isNotEmpty ? embed : m3u8;
    }
    if (url.isEmpty) {
      url = '${AppConfig.baseUrl}/phim/$slug';
    }

    void _navigateToWatch() {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => WatchScreen(
            movieId: movieId,
            episodeId: targetEp?['id'] ?? savedEpId ?? 1,
            serverIdx: savedServerIdx,
            streamUrl: url,
            movieSlug: slug,
            movieTitle: title,
            initialPosition: (progress['position'] as int?) ?? 0,
          ),
        ),
      );
    }

    _navigateToWatch();
  }

  @override
  Widget build(BuildContext context) {
    final statusBarHeight = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Stack(
        children: [
          // Nội dung chính — CustomScrollView chứa banner + content
          RefreshIndicator(
            onRefresh: _fetchMovieDetail,
            color: AppTheme.accent,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                // Banner
                if (!_isLoading && _error == null && _movieData != null)
                  SliverToBoxAdapter(
                    child: _buildHeader(Movie.fromJson(_movieData!)),
                  ),
                // Content
                if (_isLoading)
                  SliverFillRemaining(child: _buildLoading())
                else if (_error != null)
                  SliverFillRemaining(child: _buildError())
                else
                  SliverToBoxAdapter(child: _buildContent()),
                // Bottom padding cho BottomNav
                const SliverToBoxAdapter(
                  child: SizedBox(height: 80),
                ),
              ],
            ),
          ),
          // Header ẩn trên trang movie detail
          // BottomNav với spring animation
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Builder(
              builder: (context) {
                final auth = context.watch<AuthProvider>();
                return BottomNav(
                  currentIndex: _navIndex,
                  onTabSelected: _onNavSelected,
                  avatarUrl: auth.isLoggedIn ? (() {
                    final raw = auth.user?['avatar']?.toString() ?? '';
                    return raw.isNotEmpty && !raw.startsWith('http') ? '${AppConfig.baseUrl}$raw' : raw;
                  })() : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Column(
      children: [
        Container(height: 12), // gap under Header
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: const [
                ShimmerLoading(width: double.infinity, height: 220),
                SizedBox(height: 16),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: ShimmerLoading(width: double.infinity, height: 22, borderRadius: 4),
                ),
                SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: ShimmerLoading(width: 200, height: 16, borderRadius: 4),
                ),
                SizedBox(height: 24),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: ShimmerLoading(width: double.infinity, height: 120, borderRadius: 8),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      children: [
        Container(height: 12), // gap under Header
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 56, color: AppTheme.textMuted),
                  const SizedBox(height: 16),
                  const Text(
                    'Không thể tải thông tin phim',
                    style: TextStyle(color: AppTheme.textSub, fontSize: 15),
                  ),
                  const SizedBox(height: 24),
                  GestureDetector(
                    onTap: _fetchMovieDetail,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppTheme.gold,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'Thử lại',
                        style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_movieData == null) return _buildError();
    final movie = Movie.fromJson(_movieData!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Synopsis
        if ((movie.description ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    movie.description!.replaceAll('&nbsp;', ' ').replaceAll(RegExp(r'<[^>]*>'), '').trim(),
                    maxLines: 3, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppTheme.textSub, fontSize: 14, height: 1.6),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _showInfoBottomSheet(movie),
                  child: Container(
                    padding: const EdgeInsets.only(left: 8),
                    decoration: const BoxDecoration(
                      border: Border(
                        left: BorderSide(color: AppTheme.border, width: 1),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Chi tiết', style: TextStyle(color: AppTheme.textSub, fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        const Icon(Icons.keyboard_arrow_down_rounded, color: AppTheme.textSub, size: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        // 5 Action buttons
        _buildActionRow(movie),
        const SizedBox(height: 12),
        // Tabs
        Container(
          color: AppTheme.bg,
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            indicatorColor: Color(0xFFF5E6B8),
            indicatorWeight: 3,
            labelColor: Color(0xFFF5E6B8),
            unselectedLabelColor: AppTheme.textSub,
            labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            unselectedLabelStyle: const TextStyle(fontSize: 14),
            overlayColor: WidgetStateProperty.all(Colors.transparent),
            splashFactory: NoSplash.splashFactory,
            tabs: const [
              Tab(text: 'Tập phim'),
              Tab(text: 'Phòng trưng bày'),
              Tab(text: 'Diễn viên'),
              Tab(text: 'Đề xuất'),
            ],
          ),
        ),
        // Tab content
        _buildTabContent(_tabController.index, movie),
      ],
    );
  }

  // Info bottom sheet
  void _showInfoBottomSheet(Movie movie) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      clipBehavior: Clip.none,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7, maxChildSize: 0.9, minChildSize: 0.4, expand: false,
        builder: (ctx, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Xóa drag handle — ẩn đi
              const SizedBox(height: 8),
              const Text('Thông tin phim', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 20),
              Text('Giới thiệu:', style: TextStyle(color: AppTheme.textMuted, fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text((movie.description ?? '').replaceAll('&nbsp;', ' ').replaceAll(RegExp(r'<[^>]*>'), '').trim(),
                style: TextStyle(color: AppTheme.textSub, fontSize: 14, height: 1.7)),
              const SizedBox(height: 24),
              _infoRow('Quốc gia:', _countriesText().isNotEmpty ? _countriesText() : 'Đang cập nhật'),
              _infoRow('Đạo diễn:', movie.director ?? 'Đang cập nhật'),
              _infoRow('Sản xuất:', 'Đang cập nhật'),
              _infoRow('Thời lượng:', movie.time ?? '? phút/tập'),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: AppTheme.border), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: const Text('Đóng', style: TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 100, child: Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 14, fontWeight: FontWeight.w600))),
          Expanded(child: Text(value, style: TextStyle(color: AppTheme.textSub, fontSize: 14))),
        ],
      ),
    );
  }

  Widget _buildTabContent(int index, Movie movie) {
    switch (index) {
      case 0: return _buildEpisodesTab();
      case 1: return _buildGalleryTab();
      case 2: return _buildActorsTab();
      case 3: return _buildRelatedTab();
      default: return _buildEpisodesTab();
    }
  }

  // ── Rating methods ──
  final Map<int, String> _ratingLabels = {10: 'Tuyệt vời', 8: 'Phim hay', 6: 'Khá ổn', 4: 'Phim chán', 2: 'Đồ tệ'};
  final Map<int, String> _ratingEmojis = {10: '😍', 8: '😘', 6: '😊', 4: '😢', 2: '🤮'};

  void _showRatingDialog(Movie movie) {
    if (!_isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng đăng nhập để đánh giá'), backgroundColor: Colors.orange),
      );
      return;
    }
    int selectedScore = _myRating > 0 ? _myRating : 8;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Đánh giá "${movie.name}"', style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text('$_ratingCount lượt đánh giá', style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [2, 4, 6, 8, 10].map((score) {
                  final isSelected = score == selectedScore;
                  return GestureDetector(
                    onTap: () => setModalState(() => selectedScore = score),
                    child: Column(
                      children: [
                        Text(_ratingEmojis[score]!, style: TextStyle(fontSize: isSelected ? 36 : 28)),
                        const SizedBox(height: 4),
                        Text(_ratingLabels[score]!, style: TextStyle(
                          color: isSelected ? AppTheme.gold : AppTheme.textMuted,
                          fontSize: 11,
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                        )),
                      ],
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.gold, foregroundColor: const Color(0xFF1A1100), padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _submitRating(_currentMovieId, selectedScore);
                  },
                  child: const Text('Gửi đánh giá', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submitRating(int movieId, int score) async {
    try {
      final res = await ApiClient.post('/ratings.php', data: {'movie_id': movieId, 'score': score});
      final data = res.data;
      if (data['success'] == true) {
        setState(() {
          _avgRating = (data['avg_rating'] as num?)?.toDouble() ?? 0;
          _ratingCount = data['rating_count'] ?? 0;
          _myRating = data['my_rating'] ?? score;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Đã đánh giá ${_ratingEmojis[score]} ${_ratingLabels[score]}'), backgroundColor: const Color(0xFF2E7D32)),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(data['message'] ?? 'Lỗi đánh giá'), backgroundColor: Colors.redAccent),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _fetchRatings(int movieId) async {
    try {
      final res = await ApiClient.get('/ratings.php', params: {'movie_id': movieId.toString()});
      final data = res.data;
      if (data['success'] == true) {
        setState(() {
          _ratings = data['ratings'] ?? [];
          _avgRating = (data['avg_rating'] as num?)?.toDouble() ?? 0;
          _ratingCount = data['rating_count'] ?? 0;
          _myRating = data['my_rating'] ?? 0;
        });
      }
    } catch (_) {}
  }

  Widget _buildRatingItem(dynamic r) {
    final score = r['score'] ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: AppTheme.bgSurface,
            child: Text(((r['username'] ?? '?')[0] as String).toUpperCase(), style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(r['username'] ?? 'Guest', style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 6),
                    Text(_ratingEmojis[score] ?? '', style: const TextStyle(fontSize: 16)),
                    const SizedBox(width: 4),
                    Text(_ratingLabels[score] ?? '', style: TextStyle(color: AppTheme.textSub, fontSize: 11)),
                    const Spacer(),
                    Text(r['created_at'] ?? '', style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                  ],
                ),
                if ((r['comment'] ?? '').isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(r['comment'], style: const TextStyle(color: AppTheme.textSub, fontSize: 13, height: 1.5)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow(Movie movie) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          // Yêu thích — heart SVG
          _actionCircle(
            icon: Consumer<FavoriteProvider>(
              builder: (_, fav, __) => SvgPicture.asset(
                'assets/images/icon_heart.svg',
                width: 24, height: 24,
                colorFilter: ColorFilter.mode(
                  fav.isFavorite(movie.id) ? Colors.redAccent : AppTheme.textPrimary,
                  BlendMode.srcIn,
                ),
              ),
            ),
            label: 'Yêu thích',
            onTap: () => context.read<FavoriteProvider>().toggleFavorite(movie),
          ),
          // Thêm vào — add SVG
          _actionCircle(
            icon: SvgPicture.asset('assets/images/icon_add.svg', width: 24, height: 24,
              colorFilter: const ColorFilter.mode(AppTheme.textPrimary, BlendMode.srcIn)),
            label: 'Thêm vào', onTap: () {},
          ),
          // Tải về — download cloud SVG
          _actionCircle(
            icon: SvgPicture.asset('assets/svg_phimchitiet/download-cloud-svgrepo-com.svg', width: 24, height: 24,
              colorFilter: const ColorFilter.mode(AppTheme.textPrimary, BlendMode.srcIn)),
            label: 'Tải về',
            onTap: () {
              if (_servers.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Đang tải dữ liệu phim...'), backgroundColor: Colors.orange, duration: Duration(seconds: 2)),
                );
                return;
              }
              final slug = movie.slug ?? (_movieData?['slug'] ?? '');
              final title = movie.name ?? (_movieData?['name'] ?? '');
              final thumb = movie.thumbUrl ?? (_movieData?['thumb_url'] ?? '');
              final epType = (_movieData?['type'] ?? '').toString().toLowerCase();
              final isSeries = epType.contains('series') || epType.contains('hoạt hình');
              showDownloadDialog(
                context: context,
                movieId: movie.id,
                movieName: title,
                movieSlug: slug,
                movieThumb: thumb,
                servers: _servers.cast<Map<String, dynamic>>(),
                serverSources: _serverSources.cast<Map<String, dynamic>>(),
                isSeries: isSeries,
              );
            },
          ),
          // Đánh giá — mood SVG + badge
          _actionCircle(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                SvgPicture.asset('assets/images/icon_mood.svg', width: 24, height: 24,
                  colorFilter: const ColorFilter.mode(AppTheme.textPrimary, BlendMode.srcIn)),
                if (_avgRating > 0)
                  Positioned(
                    top: -6, right: -10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(color: AppTheme.gold, borderRadius: BorderRadius.circular(6)),
                      child: Text(_avgRating.toStringAsFixed(1), style: const TextStyle(color: Color(0xFF1A1100), fontSize: 9, fontWeight: FontWeight.w800)),
                    ),
                  ),
              ],
            ),
            label: 'Đánh giá', onTap: () => _showRatingDialog(movie),
          ),
          // Bình luận — comment SVG
          _actionCircle(
            icon: SvgPicture.asset('assets/images/icon_comment.svg', width: 24, height: 24,
              colorFilter: const ColorFilter.mode(AppTheme.textPrimary, BlendMode.srcIn)),
            label: 'Bình luận', onTap: () {},
          ),
          // Chia sẻ — send SVG
          _actionCircle(
            icon: SvgPicture.asset('assets/images/icon_send.svg', width: 24, height: 24,
              colorFilter: const ColorFilter.mode(AppTheme.textPrimary, BlendMode.srcIn)),
            label: 'Chia sẻ',
            onTap: () {
              final slug = movie.slug ?? (_movieData?['slug'] ?? '');
              Clipboard.setData(ClipboardData(text: 'https://xiaofilm.online/phim/$slug'));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Đã copy link phim'), backgroundColor: Color(0xFF2E7D32), duration: Duration(seconds: 2)),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _actionCircle({required Widget icon, required String label, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          SizedBox(width: 44, height: 44, child: Center(child: icon)),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: AppTheme.textSub, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildGalleryTab() {
    if (_galleryImages.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_library_outlined, size: 56, color: AppTheme.textMuted),
            SizedBox(height: 12),
            Text('Chưa có ảnh', style: TextStyle(color: AppTheme.textSub, fontSize: 14)),
          ],
        ),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: Responsive.isMobile(context) ? 2 : 4,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 16 / 9,
      ),
      itemCount: _galleryImages.length,
      itemBuilder: (context, index) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: '${_galleryImages[index]}?v=${DateTime.now().millisecondsSinceEpoch ~/ 60000}',
            fit: BoxFit.cover,
            cacheManager: AppImageCacheManager(),
            fadeInDuration: const Duration(milliseconds: 200),
            fadeOutDuration: const Duration(milliseconds: 100),
            placeholder: (_, __) => Container(color: AppTheme.bgCard),
            errorWidget: (_, __, ___) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && index < _galleryImages.length) {
                  setState(() => _galleryImages.removeAt(index));
                }
              });
              return const SizedBox.shrink();
            },
          ),
        );
      },
    );
  }

  int get _totalCommentCount {
    int count = 0;
    for (final c in _comments) {
      count++;
      final replies = c['replies'];
      if (replies is List) count += replies.length;
    }
    return count;
  }

  Widget _buildCommentsSection(Movie movie) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          // Header with icon + count + toggle tabs
          Row(
            children: [
              Icon(
                _commentTab == 0 ? Icons.chat_bubble_outline_rounded : Icons.star_rounded,
                color: _commentTab == 1 ? const Color(0xFFF5C518) : AppTheme.textPrimary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                _commentTab == 0 ? 'Bình luận ($_totalCommentCount)' : 'Đánh giá ($_ratingCount)',
                style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Container(
                decoration: BoxDecoration(
                  color: AppTheme.bgCard,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Row(
                  children: [
                    _commentTabBtn('Bình luận', _commentTab == 0, () => setState(() => _commentTab = 0)),
                    _commentTabBtn('Đánh giá', _commentTab == 1, () => setState(() => _commentTab = 1)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Content based on tab
          if (_commentTab == 0) ...[
            _buildCommentInput(),
            const SizedBox(height: 16),
            if (_comments.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('Chưa có bình luận nào', style: TextStyle(color: AppTheme.textMuted, fontSize: 13))),
              )
            else
              ..._comments.take(50).map((c) => _buildCommentItem(c)),
          ] else ...[
            // Rating input
            _buildRatingInput(movie),
            const SizedBox(height: 16),
            if (_ratings.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('Chưa có đánh giá nào', style: TextStyle(color: AppTheme.textMuted, fontSize: 13))),
              )
            else
              ..._ratings.take(10).map((r) => _buildRatingItem(r)),
          ],
        ],
      ),
    );
  }

  Widget _buildRatingInput(Movie movie) {
    return GestureDetector(
      onTap: () => _showRatingDialog(movie),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: AppTheme.bgSurface,
              child: Text(
                _isLoggedIn ? ((_currentUser['username'] ?? '?')[0] as String).toUpperCase() : '?',
                style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _myRating > 0 ? 'Đánh giá của bạn: ${_ratingEmojis[_myRating]} ${_ratingLabels[_myRating]}' : 'Nhấn để đánh giá phim này',
                style: TextStyle(color: _myRating > 0 ? AppTheme.textPrimary : AppTheme.textMuted, fontSize: 13),
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _commentTabBtn(String label, bool isActive, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isActive ? const Color(0x1AFFFFFF) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: isActive ? Border.all(color: Colors.white.withValues(alpha: 0.5)) : null,
        ),
        child: Text(label, style: TextStyle(
          color: isActive ? AppTheme.textPrimary : AppTheme.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        )),
      ),
    );
  }

  Widget _buildCommentInput() {
    if (!_isLoggedIn) {
      return GestureDetector(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AuthScreen())),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.bgCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: const Row(
            children: [
              Icon(Icons.login_rounded, color: AppTheme.textMuted, size: 20),
              SizedBox(width: 10),
              Text('Vui lòng đăng nhập để tham gia bình luận', style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
            ],
          ),
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: AppTheme.bgSurface,
          backgroundImage: (_currentUser['avatar'] != null && (_currentUser['avatar'] as String).isNotEmpty)
              ? NetworkImage(_fixAvatarUrl(_currentUser['avatar']))
              : null,
          child: (_currentUser['avatar'] == null || (_currentUser['avatar']?.toString() ?? '').isEmpty)
              ? Text(((_currentUser['username'] ?? '?')[0] as String).toUpperCase(),
                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w700))
              : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Bình luận với tên ${_currentUser['username'] ?? ''}', style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
              const SizedBox(height: 4),
              TextField(
                controller: _commentController,
                maxLines: 3,
                minLines: 2,
                maxLength: 1000,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Viết bình luận',
                  hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                  counterText: '${_commentController.text.length} / 1000',
                  counterStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  filled: true,
                  fillColor: AppTheme.bgCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppTheme.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppTheme.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppTheme.gold),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  // Spoiler toggle
                  GestureDetector(
                    onTap: () => setState(() => _isSpoiler = !_isSpoiler),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 18,
                          decoration: BoxDecoration(
                            color: _isSpoiler ? AppTheme.gold : AppTheme.textMuted.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: AnimatedAlign(
                            duration: const Duration(milliseconds: 200),
                            alignment: _isSpoiler ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              width: 14,
                              height: 14,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text('Tiết lộ?', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // Gửi button
                  GestureDetector(
                    onTap: _isPostingComment ? null : _postComment,
                    child: Row(
                      children: [
                        Text('Gửi', style: TextStyle(
                          color: _commentController.text.trim().isEmpty ? AppTheme.textMuted : AppTheme.gold,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        )),
                        const SizedBox(width: 4),
                        Icon(Icons.send_rounded, color: _commentController.text.trim().isEmpty ? AppTheme.textMuted : AppTheme.gold, size: 18),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCommentItem(dynamic c, {bool isReply = false}) {
    final commentId = c['id'];
    final votes = _commentVotes[commentId] ?? {'up': 0, 'down': 0};
    final myVote = _myVotes[commentId] ?? 0;
    final isSpoiler = c['spoiler'] == true || c['spoiler'] == 1;
    final cUsername = c['username'] ?? c['guest_name'] ?? 'Ẩn danh';
    final cAvatar = c['avatar']?.toString();
    final cTime = _timeAgo(c['created_at'] != null ? DateTime.tryParse(c['created_at'].toString()) : null);
    final cUserId = c['user_id'];
    final isMine = _isLoggedIn && cUserId != null && cUserId == (_currentUser['id'] ?? _currentUser['_id']);

    Widget contentWidget = Text(c['content'] ?? '', style: const TextStyle(color: AppTheme.textSub, fontSize: 13, height: 1.5));

    if (isSpoiler) {
      contentWidget = GestureDetector(
        onTap: () => setState(() => c['_revealed'] = !(c['_revealed'] ?? false)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (c['_revealed'] ?? false) ? const Color(0x334CAF50) : const Color(0x33F5C518),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  (c['_revealed'] ?? false) ? 'Spoiler — đã hiện' : '⚠ Spoiler — bấm để hiện',
                  style: TextStyle(
                    color: (c['_revealed'] ?? false) ? const Color(0xFF4CAF50) : const Color(0xFFF5C518),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              ClipRect(
                child: (c['_revealed'] ?? false)
                    ? contentWidget
                    : ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                        child: contentWidget,
                      ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(bottom: 12, left: isReply ? 36 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: isReply ? 12 : 14,
                backgroundColor: isReply ? const Color(0x1AFFFFFF) : AppTheme.bgSurface,
                backgroundImage: (cAvatar != null && cAvatar.isNotEmpty) ? NetworkImage(_fixAvatarUrl(cAvatar)) : null,
                child: (cAvatar == null || cAvatar.isEmpty)
                    ? Text((cUsername.isNotEmpty ? cUsername[0] : '?').toUpperCase(),
                        style: TextStyle(color: AppTheme.textPrimary, fontSize: isReply ? 10 : 11, fontWeight: FontWeight.w700))
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(cUsername,
                              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 6),
                        if (cTime.isNotEmpty)
                          Text(cTime, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    contentWidget,
                  ],
                ),
              ),
            ],
          ),
          // Action row: vote + reply + delete
          Padding(
            padding: const EdgeInsets.only(left: 38, top: 4),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => _voteComment(commentId, 1),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.keyboard_arrow_up_rounded, size: 18,
                          color: myVote == 1 ? AppTheme.gold : AppTheme.textMuted),
                      if ((votes['up'] ?? 0) > 0)
                        Text('${votes['up']}', style: TextStyle(fontSize: 11,
                            color: myVote == 1 ? AppTheme.gold : AppTheme.textMuted)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _voteComment(commentId, -1),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.keyboard_arrow_down_rounded, size: 18,
                          color: myVote == -1 ? Colors.redAccent : AppTheme.textMuted),
                      if ((votes['down'] ?? 0) > 0)
                        Text('${votes['down']}', style: TextStyle(fontSize: 11,
                            color: myVote == -1 ? Colors.redAccent : AppTheme.textMuted)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (!isReply)
                  GestureDetector(
                    onTap: () => _startReply(commentId, cUsername),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.reply_rounded, size: 14, color: AppTheme.textMuted),
                        SizedBox(width: 3),
                        Text('Trả lời', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                      ],
                    ),
                  ),
                if (isMine) ...[
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => _deleteComment(commentId),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.delete_outline_rounded, size: 14, color: AppTheme.textMuted),
                        SizedBox(width: 3),
                        Text('Xóa', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Reply input
          if (_replyParentId == commentId)
            Padding(
              padding: const EdgeInsets.only(left: 38, top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _replyController,
                      autofocus: true,
                      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
                      decoration: InputDecoration(
                        hintText: 'Trả lời $cUsername...',
                        hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                        filled: true,
                        fillColor: AppTheme.bgCard,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.border)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.border)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _submitReply,
                    child: Icon(Icons.send_rounded, color: AppTheme.gold, size: 20),
                  ),
                ],
              ),
            ),
          // Replies
          if (c['replies'] != null && (c['replies'] as List).isNotEmpty)
            ...((c['replies'] as List).map((r) => _buildCommentItem(r, isReply: true))),
        ],
      ),
    );
  }

  int? _replyParentId;
  String _replyToName = '';
  final TextEditingController _replyController = TextEditingController();

  void _startReply(int parentId, String userName) {
    if (!_isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng đăng nhập để trả lời'), backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() {
      _replyParentId = parentId;
      _replyToName = userName;
      _replyController.clear();
    });
  }

  void _cancelReply() {
    setState(() {
      _replyParentId = null;
      _replyController.clear();
    });
  }

  Future<void> _submitReply() async {
    if (_replyController.text.trim().isEmpty || _replyParentId == null) return;
    try {
      final movieId = _currentMovieId;
      await ApiClient.post('/comments.php', data: {
        'movie_id': movieId,
        'content': _replyController.text.trim(),
        'parent_id': _replyParentId,
        'spoiler': _isSpoiler ? 1 : 0,
      });
      _replyController.clear();
      _replyParentId = null;
      _fetchComments();
    } catch (_) {}
  }

  // ── Vote system ──
  Map<int, Map<String, int>> _commentVotes = {};
  Map<int, int> _myVotes = {};

  Future<void> _voteComment(int commentId, int direction) async {
    if (!_isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đăng nhập để vote'), backgroundColor: Colors.orange),
      );
      return;
    }
    try {
      final res = await ApiClient.post('/votes.php', data: {
        'comment_id': commentId,
        'direction': direction,
        'movie_id': _currentMovieId,
      });
      final data = res.data;
      if (data['success'] == true) {
        setState(() {
          _commentVotes[commentId] = {'up': data['up'] ?? 0, 'down': data['down'] ?? 0};
          _myVotes[commentId] = data['my_vote'] ?? 0;
        });
      }
    } catch (_) {}
  }

  Future<void> _deleteComment(int commentId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: const Text('Xóa bình luận', style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text('Bạn có chắc muốn xóa bình luận này?', style: TextStyle(color: AppTheme.textSub)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xóa', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final res = await ApiClient.dio.delete('/comments.php', data: {
        'comment_id': commentId,
      });
      if (res.data['success'] == true) {
        _fetchComments();
      }
    } catch (_) {}
  }

  Future<void> _fetchVotes() async {
    try {
      final res = await ApiClient.get('/votes.php', params: {'movie_id': _currentMovieId.toString()});
      final data = res.data;
      if (data['success'] == true && data['votes'] is Map) {
        final votesMap = data['votes'] as Map;
        setState(() {
          _commentVotes = {};
          votesMap.forEach((key, value) {
            final id = int.tryParse(key.toString());
            if (id != null && value is Map) {
              _commentVotes[id] = {'up': value['up'] ?? 0, 'down': value['down'] ?? 0};
            }
          });
        });
      }
    } catch (_) {}
  }

  Widget _buildHeader(Movie movie) {
    final quality = (movie.quality ?? '').toUpperCase();
    final backdropUrl = movie.posterUrl ?? movie.thumbUrl ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Banner — full width, fixed 16:9 aspect ratio
        Hero(
          tag: 'movie_poster_${_movieData?['id'] ?? 0}',
          child: Stack(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: CachedNetworkImage(
                  imageUrl: backdropUrl,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  memCacheWidth: (MediaQuery.of(context).size.width * 2).toInt(),
                  cacheManager: AppImageCacheManager(),
                  fadeInDuration: const Duration(milliseconds: 250),
                  fadeOutDuration: Duration.zero,
                  placeholder: (_, __) => Container(color: AppTheme.bgCard),
                  errorWidget: (_, __, ___) => Container(color: AppTheme.bgCard),
                ),
              ),
              Positioned(
                top: MediaQuery.of(context).padding.top + 8, left: 12,
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 36, height: 36,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x80000000)),
                    child: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ],
          ),
        ),
        // 2 buttons — 10px dưới banner
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    dynamic firstEp;
                    if (_servers.isNotEmpty) {
                      final eps = _servers[_selectedServer]['episodes'] as List<dynamic>? ?? [];
                      if (eps.isNotEmpty) firstEp = eps[0];
                    }
                    if (firstEp == null && _episodes.isNotEmpty) firstEp = _episodes[0];
                    if (firstEp != null) _tapEpisode(firstEp, 0);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(color: const Color(0xFFF5E6B8), borderRadius: BorderRadius.circular(12)),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.play_arrow_rounded, color: Color(0xFF1A1100), size: 22),
                        SizedBox(width: 8),
                        Text('Xem phim', style: TextStyle(color: Color(0xFF1A1100), fontSize: 16, fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () {},
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.list_rounded, color: Color(0xFF1A1100), size: 20),
                      SizedBox(width: 8),
                      Text('Tập Phim', style: TextStyle(color: Color(0xFF1A1100), fontSize: 15, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // ★ Xem tiếp button — hiển thị khi có watch progress
        if (_watchProgress != null) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildResumeBanner(movie),
          ),
        ],
        // Title + Chips — 10px dưới buttons/xem tiếp
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(movie.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: GoogleFonts.merienda(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
              if ((movie.originName ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(movie.originName!, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 14)),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: [
                  _chipSolid('IMDb ${(movie.tmdbRating ?? movie.imdbRating ?? 0).toStringAsFixed(1)}'),
                  _chipSolid((movie.ageRating ?? '').toUpperCase().isNotEmpty ? movie.ageRating!.toUpperCase() : 'P'),
                  if (quality.isNotEmpty) _chipBorder(quality, true),
                  if (movie.year != null && movie.year! > 0) _chipBorder('${movie.year}', (movie.year ?? 0) >= 2026),
                  if ((movie.time ?? '').isNotEmpty) _chipBorder(movie.time!, false),
                  ..._buildServerEpChips(),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Chip nền trắng đậm — dùng cho TMDB, T16, T13
  Widget _chipSolid(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: const TextStyle(color: Color(0xFF1A1A2E), fontSize: 11, fontWeight: FontWeight.w800)),
    );
  }

  /// Chip viền trắng — dùng cho year 2026+, type, quality
  Widget _chipBorder(String label, bool isModern) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isModern ? Colors.white.withValues(alpha: 0.7) : Colors.white,
          width: isModern ? 1.2 : 0.8,
        ),
      ),
      child: Text(label, style: TextStyle(
        color: isModern ? Colors.white : Colors.white70,
        fontSize: 11, fontWeight: FontWeight.w600,
      )),
    );
  }

  List<Widget> _buildServerEpChips() {
    if (_servers.isEmpty) return [];

    // Group servers by type, keep max episode count per type
    final Map<String, int> typeMaxEps = {};

    for (int i = 0; i < _servers.length; i++) {
      final sName = (_servers[i]['server_name'] ?? '').toString().toLowerCase();
      final eps = (_servers[i]['episodes'] as List<dynamic>?) ?? [];
      if (eps.isEmpty) continue;

      String type;
      if (sName.contains('thuyết minh') || sName.contains('tm') || sName.contains('dub')) {
        type = 'TM';
      } else if (sName.contains('vietsub') || sName.contains('phụ đề') || sName.contains('pd') || sName.contains('đ')) {
        type = 'PĐ';
      } else if (sName.contains('4k')) {
        type = '4K';
      } else if (sName.contains('raw') || sName.contains('raws')) {
        type = 'RW';
      } else if (sName.contains('playlist')) {
        type = 'PL';
      } else {
        type = sName.length > 3 ? sName.substring(0, 2).toUpperCase() : sName.toUpperCase();
      }

      // Keep highest episode count for each type
      final epCount = eps.length;
      if (!typeMaxEps.containsKey(type) || epCount > typeMaxEps[type]!) {
        typeMaxEps[type] = epCount;
      }
    }

    if (typeMaxEps.isEmpty) return [];

    // Build combined chip: TM.40/PĐ.42
    final parts = typeMaxEps.entries.map((e) => '${e.key}.${e.value}').toList();
    return [_chipBorder(parts.join('/'), false)];
  }

  Widget _buildInfoPanel(Movie movie) {
    if (!_showInfoPanel) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
                  // Tags row
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _infoTag('TMDB ${(movie.tmdbRating ?? 0).toStringAsFixed(1)}', Colors.transparent, const Color(0xFFF5C518), border: const Color(0xFFF5C518)),
                      _infoTag(_formatAgeRating(movie.ageRating), Colors.white, Colors.black),
                      if (movie.year != null && movie.year! > 0)
                        _infoTag('${movie.year}', Colors.transparent, Colors.white, border: Colors.white.withValues(alpha: 0.5)),
                      _infoTag(_episodeTagText(movie), Colors.transparent, Colors.white, border: Colors.white.withValues(alpha: 0.5)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Genre tags
                  if (_genresText().isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _genresText().split(', ').map((g) => _genreChip(g)).toList(),
                    ),
                  if (_genresText().isNotEmpty) const SizedBox(height: 12),
                  // Status badge — completed or airing
                  if ((movie.episodeCurrent ?? '').isNotEmpty)
                    _buildStatusBadge(movie),
                  const SizedBox(height: 12),
                  // Synopsis
                  if ((movie.description ?? '').isNotEmpty) ...[
                    Text('Giới thiệu:', style: TextStyle(color: AppTheme.textMuted, fontSize: 13, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                      movie.description!.replaceAll('&nbsp;', ' ').replaceAll(RegExp(r'<[^>]*>'), '').trim(),
                      style: TextStyle(color: AppTheme.textSub, fontSize: 13, height: 1.7),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Detail rows
                  _infoDetailRow('Thời lượng:', movie.time ?? '--'),
                  _infoDetailRow('Quốc gia:', _countriesText().isNotEmpty ? _countriesText() : '--'),
                  if (_actorsText().isNotEmpty)
                    _infoDetailRow('Diễn viên:', _actorsText()),
                  if (movie.imdbRating != null && movie.imdbRating! > 0)
                    _infoDetailRow('IMDb:', movie.imdbRating!.toStringAsFixed(1)),
                  // Keywords
                  if (_genresText().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text('Từ khóa:', style: TextStyle(color: AppTheme.textMuted, fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(
                      _genresText(),
                      style: TextStyle(color: AppTheme.textSub, fontSize: 12, height: 1.8),
                    ),
                  ],
        ],
      ),
    );
  }

  Widget _infoTag(String label, Color bgColor, Color textColor, {Color? border}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
        border: border != null ? Border.all(color: border, width: 1) : null,
      ),
      child: Text(label, style: TextStyle(color: textColor, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }

  Widget _genreChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x0FFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border),
      ),
      child: Text(label, style: TextStyle(color: AppTheme.textSub, fontSize: 11)),
    );
  }

  Widget _infoDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 85,
            child: Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
          ),
          Expanded(
            child: Text(value, style: TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  String _genresText() {
    final genres = _movieData?['genres'];
    if (genres is List && genres.isNotEmpty) {
      return genres.map((g) => g['name']?.toString() ?? '').where((s) => s.isNotEmpty).join(', ');
    }
    return '';
  }

  Widget _buildStatusBadge(Movie movie) {
    final current = movie.episodeCurrent ?? '';
    final total = movie.episodeTotal ?? '';
    final isTrailer = current.toLowerCase().contains('trailer');
    final isCompleted = current.toLowerCase().contains('hoàn thành') ||
        current.toLowerCase().contains('hoàn tất') ||
        (current.contains('/') && total.isNotEmpty && current.split('/')[0].trim() == total.trim());

    if (isTrailer) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0x26F5921E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0x73F5921E)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_rounded, color: Color(0xFFF5921E), size: 16),
            SizedBox(width: 6),
            Text(
              'Phim đang chiếu: Trailer',
              style: TextStyle(color: Color(0xFFF5921E), fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    if (isCompleted) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0x2622C55E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0x7322C55E)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, color: Color(0xFF22C55E), size: 16),
            const SizedBox(width: 6),
            Text(
              'Hoàn tất${total.isNotEmpty ? ' ($total/$total)' : ''}',
              style: const TextStyle(color: Color(0xFF22C55E), fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    } else {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0x26F5921E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0x73F5921E)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFFF5921E),
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFF5921E)),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Phim đang chiếu: ${_episodeText(movie)}',
              style: const TextStyle(color: Color(0xFFF5921E), fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }
  }

  Widget _detailPill(String label, Color bg, Color textColor, {Color? borderColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: borderColor != null ? Border.all(color: borderColor, width: 1) : null,
      ),
      child: Text(label, style: TextStyle(color: textColor, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }

  String _typeLabel(String t) {
    switch (t) {
      case 'series': return 'Phim bộ';
      case 'hoathinh': return 'Hoạt hình';
      case 'tvshows': return 'TV Shows';
      default: return t;
    }
  }

  Widget _backButton() {
    return IconButton(
      icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
      onPressed: () => Navigator.pop(context),
    );
  }

  /// Action bar nổi trên banner — chỉ nút back
  Widget _buildActionBar(Movie movie) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          _backButton(),
        ],
      ),
    );
  }

  String _formatViews(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(0)}K';
    return '$v';
  }

  String _episodeText(Movie movie) {
    final current = movie.episodeCurrent ?? '';
    final total = movie.episodeTotal ?? '';

    // "Hoàn thành (37/37)" → giữ nguyên
    if (current.contains('Hoàn thành')) return current;

    // "37/37" hoặc "37 / 37" → đã hoàn thành, chỉ lấy số đầu
    if (current.contains('/')) {
      final parts = current.split('/');
      final epNum = parts[0].trim().replaceAll(RegExp(r'[^0-9]'), '');
      if (epNum.isNotEmpty && total.isNotEmpty) return '$epNum / $total';
      if (epNum.isNotEmpty) return epNum;
    }

    // Chỉ trả số, không thêm "tập" (vì label đã có "Số tập")
    final currentNum = current.replaceAll(RegExp(r'[^0-9]'), '');
    if (currentNum.isNotEmpty && total.isNotEmpty) return '$currentNum / $total';
    if (currentNum.isNotEmpty) return currentNum;
    if (total.isNotEmpty) return total;
    return '--';
  }

  String _episodeTagText(Movie movie) {
    final current = movie.episodeCurrent ?? '';
    final total = movie.episodeTotal ?? '';

    if (current.contains('Hoàn thành') || current.contains('Hoàn tất')) {
      return 'Hoàn tất ${_episodeText(movie)}';
    }
    if (current.contains('/')) {
      return _episodeText(movie);
    }
    return 'Phần 1';
  }

  String _formatAgeRating(String? rating) {
    if (rating == null || rating.isEmpty) return 'P';
    final clean = rating.replaceAll(RegExp(r'^[TtPp]\.?\s*'), '');
    if (RegExp(r'^\d+$').hasMatch(clean)) return 'T.$clean';
    return rating;
  }

  String _countriesText() {
    final countries = _movieData?['countries'];
    if (countries is List && countries.isNotEmpty) {
      return countries.map((c) => c['name']?.toString() ?? '').where((s) => s.isNotEmpty).join(', ');
    }
    return '';
  }

  String _actorsText() {
    // Ưu tiên actor_vi (đã dịch Hán Việt từ API)
    final actorVi = _movieData?['actor_vi'];
    if (actorVi is String && actorVi.trim().isNotEmpty) return actorVi.trim();
    // Fallback: actor raw
    final raw = _movieData?['actor'] ?? _movieData?['actors'] ?? _movieData?['casts'];
    if (raw is List && raw.isNotEmpty) {
      return raw.map((e) => e.toString()).where((s) => s.isNotEmpty).join(', ');
    }
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    // Fallback từ Movie model
    final movie = Movie.fromJson(_movieData!);
    if (movie.actors != null && movie.actors!.isNotEmpty) {
      return movie.actors!.join(', ');
    }
    return '';
  }

  Widget _actionBtn({
    required String label,
    IconData? icon,
    Color? iconColor,
    required Color? bgColor,
    required Color textColor,
    bool isGold = false,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 38,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          gradient: isGold
              ? const LinearGradient(
                  begin: Alignment(-0.8, -1),
                  end: Alignment(0.8, 1),
                  colors: [Color(0xFFFECF59), Color(0xFFFFF1CC)],
                )
              : null,
          color: isGold ? null : bgColor,
          borderRadius: BorderRadius.circular(12),
          border: isGold ? null : Border.all(color: AppTheme.border),
          boxShadow: isGold
              ? [
                  const BoxShadow(
                    color: Color(0x1AFFDA7D),
                    blurRadius: 10,
                    spreadRadius: 5,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: iconColor ?? textColor),
              const SizedBox(width: 6),
            ],
            Text(label, style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  // --- Episodes Tab ---
  Widget _buildEpisodesTab() {
    if (_servers.isEmpty && _episodes.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.video_library_outlined, size: 56, color: AppTheme.textMuted),
            SizedBox(height: 12),
            Text('Chưa có tập phim nào', style: TextStyle(color: AppTheme.textSub, fontSize: 14)),
          ],
        ),
      );
    }

    // Get servers from selected source
    final sourceServers = _serverSources.isNotEmpty && _selectedSource < _serverSources.length
        ? (_serverSources[_selectedSource]['servers'] as List<dynamic>)
        : _servers;

    // Get current server within source
    final currentServer = sourceServers.isNotEmpty && _selectedSourceServer < sourceServers.length
        ? sourceServers[_selectedSourceServer]
        : (sourceServers.isNotEmpty ? sourceServers.first : null);

    // Episodes of current server
    final currentEps = currentServer != null
        ? (currentServer['episodes'] as List<dynamic>? ?? [])
        : _episodes;

    // Pagination
    final totalEps = currentEps.length;
    final totalPages = (totalEps / _episodesPerPage).ceil();
    if (totalPages <= 1) _episodePage = 1;
    if (_episodePage > totalPages) _episodePage = totalPages;
    final startIdx = (_episodePage - 1) * _episodesPerPage;
    final endIdx = (startIdx + _episodesPerPage).clamp(0, totalEps);
    final pagedEps = currentEps.sublist(startIdx, endIdx);

    // Dropdown shows Server#1•FHD, Server#2•HD...
    final currentSourceName = _serverSources.isNotEmpty && _selectedSource < _serverSources.length
        ? (_serverSources[_selectedSource]['name'] ?? '').toString()
        : 'Server';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header: "Phần X" + source dropdown
        if (_serverSources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.menu_rounded, color: AppTheme.textPrimary, size: 20),
                const SizedBox(width: 8),
                Text(
                  (_movieData?['episode_current'] ?? 'Phần 1').toString(),
                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                PopupMenuButton<int>(
                  onSelected: (index) {
                    setState(() {
                      _selectedSource = index;
                      _selectedSourceServer = 0;
                      _episodePage = 1;
                      final servers = _serverSources[index]['servers'] as List<dynamic>;
                      if (servers.isNotEmpty) {
                        _selectedServer = _servers.indexOf(servers.first);
                      }
                    });
                  },
                  offset: const Offset(0, 30),
                  color: AppTheme.bgCard,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  itemBuilder: (ctx) => List.generate(_serverSources.length, (index) {
                    final isActive = index == _selectedSource;
                    final sourceLabel = (_serverSources[index]['name'] ?? '').toString();
                    final totalEps = _serverSources[index]['totalEps'] ?? 0;
                    return PopupMenuItem<int>(
                      value: index,
                      child: Row(
                        children: [
                          if (isActive)
                            const Icon(Icons.check_rounded, color: Color(0xFFF5E6B8), size: 16),
                          if (isActive) const SizedBox(width: 6),
                          Text(
                            '$sourceLabel ($totalEps tập)',
                            style: TextStyle(
                              color: isActive ? const Color(0xFFF5E6B8) : AppTheme.textPrimary,
                              fontSize: 13,
                              fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.bgCard,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white, width: 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          currentSourceName,
                          style: const TextStyle(color: AppTheme.textSub, fontSize: 12),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.keyboard_arrow_down_rounded, color: AppTheme.textSub, size: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

        // Server name buttons within source
        if (sourceServers.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: List.generate(sourceServers.length > 2 ? 2 : sourceServers.length, (index) {
                final isActive = index == _selectedSourceServer;
                final sName = (sourceServers[index]['server_name'] ?? '').toString();
                final serverEps = (sourceServers[index]['episodes'] as List<dynamic>?) ?? [];
                final epCount = serverEps.length;

                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: index == 0 ? 8 : 0),
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedSourceServer = index;
                          _selectedServer = _servers.indexOf(sourceServers[index]);
                          _episodePage = 1;
                        });
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: isActive ? const Color(0xFFF5E6B8) : AppTheme.bgCard,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isActive ? const Color(0xFFF5E6B8) : AppTheme.border,
                          ),
                        ),
                        child: Column(
                          children: [
                            Text(
                              sName,
                              style: TextStyle(
                                color: isActive ? const Color(0xFF1A1100) : AppTheme.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '($epCount tập)',
                              style: TextStyle(
                                color: isActive ? const Color(0xFF1A1100).withValues(alpha: 0.6) : AppTheme.textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),

        const SizedBox(height: 4),

        // Pagination controls — chỉ hiện khi > 100 tập
        if (totalPages > 1)
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: totalPages,
              itemBuilder: (context, pageIdx) {
                final pageNum = pageIdx + 1;
                final isActive = pageNum == _episodePage;
                final from = pageIdx * _episodesPerPage + 1;
                final to = ((pageIdx + 1) * _episodesPerPage).clamp(1, totalEps);
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onTap: () => setState(() => _episodePage = pageNum),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: isActive ? Colors.white.withValues(alpha: 0.15) : AppTheme.bgCard,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isActive ? Colors.white.withValues(alpha: 0.5) : AppTheme.border,
                        ),
                      ),
                      child: Text(
                        '$from-$to',
                        style: TextStyle(
                          color: isActive ? Colors.white.withValues(alpha: 0.85) : AppTheme.textSub,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

        // Episode grid — 3 columns with "Tập X" prefix
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2.0,
          ),
          itemCount: pagedEps.length,
          itemBuilder: (context, index) {
              final ep = pagedEps[index];
              final rawName = ep is Map
                  ? (ep['ep_name'] ?? ep['name'] ?? '${startIdx + index + 1}').toString()
                  : '${startIdx + index + 1}';
              final epId = ep is Map ? ep['id'] : null;
              final isActive = _watchProgress != null && epId != null && epId == _watchProgress!['episode_id'];
              final epNum = rawName.replaceAll(RegExp(r'^[Tt]ậ?p?\s*', caseSensitive: false), '').trim();
              final displayName = 'Tập $epNum';
              return GestureDetector(
                onTap: () => _tapEpisode(ep, startIdx + index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    color: isActive ? const Color(0xFFF5E6B8) : const Color(0xFF1E2130),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      displayName,
                      style: TextStyle(
                        color: isActive ? const Color(0xFF1A1100) : Colors.white.withValues(alpha: 0.85),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  void _tapEpisode(dynamic ep, int index) {
    final epId = ep is Map ? (ep['id'] ?? index) : index;
    final slug  = widget.movie?.slug ?? (_movieData?['slug'] ?? '');
    final title = widget.movie?.name ?? (_movieData?['name'] ?? '');

    // Ưu tiên link_embed, fallback link_m3u8, fallback trang web
    String url = '';
    if (ep is Map) {
      final embed = (ep['link_embed'] ?? '').toString().trim();
      final m3u8  = (ep['link_m3u8']  ?? '').toString().trim();
      url = embed.isNotEmpty ? embed : m3u8;
    }
    if (url.isEmpty) {
      url = '${AppConfig.baseUrl}/phim/$slug';
    }

    final movieId = widget.movieId > 0
        ? widget.movieId
        : (widget.movie?.id ?? (_movieData?['id'] as int? ?? 0));

    SmartLinkAd.show(context, onComplete: () {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => WatchScreen(
            movieId:    movieId,
            episodeId:  epId,
            serverIdx:  _selectedServer,
            streamUrl:  url,
            movieSlug:  slug,
            movieTitle: title,
            startFullscreen: true,
          ),
        ),
      );
    });
  }

  /// Fetch comments from server
  Future<void> _fetchComments() async {
    final movieId = _currentMovieId;
    if (movieId <= 0) return;
    try {
      final comments = await _movieService.getComments(movieId);
      if (mounted) {
        setState(() {
          _comments = comments.map((c) => c.toJson()).toList();
        });
        _fetchVotes();
      }
    } catch (_) {}
  }

  /// Post a comment
  Future<void> _postComment() async {
    final content = _commentController.text.trim();
    if (content.isEmpty) return;

    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (!auth.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng đăng nhập để bình luận'), backgroundColor: Colors.orange),
      );
      return;
    }

    final movieId = _currentMovieId;
    if (movieId <= 0) return;

    setState(() => _isPostingComment = true);
    try {
      final result = await _movieService.postComment(movieId, content, spoiler: _isSpoiler);
      final success = result['success'] == true;
      final message = result['message']?.toString() ?? '';
      if (success && mounted) {
        _commentController.clear();
        _isSpoiler = false;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã gửi bình luận'), backgroundColor: Color(0xFF2E7D32), duration: Duration(seconds: 2)),
        );
        _fetchComments();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message.isNotEmpty ? message : 'Không thể gửi bình luận'), backgroundColor: Colors.redAccent),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
    if (mounted) setState(() => _isPostingComment = false);
  }

  /// Time ago string from DateTime
  String _timeAgo(DateTime? dt) {
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'vừa xong';
    if (diff.inMinutes < 60) return '${diff.inMinutes} phút trước';
    if (diff.inHours < 24) return '${diff.inHours} giờ trước';
    if (diff.inDays < 30) return '${diff.inDays} ngày trước';
    return '${(diff.inDays / 30).floor()} tháng trước';
  }

  // --- Comments Tab ---
  Widget _buildCommentsTab() {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final userAvatar = auth.isLoggedIn ? (() {
      final raw = auth.user?['avatar']?.toString() ?? '';
      return raw.isNotEmpty && !raw.startsWith('http') ? '${AppConfig.baseUrl}$raw' : raw;
    })() : null;

    return Column(
      children: [
        // Add comment input
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppTheme.bgCard,
                child: userAvatar != null && userAvatar.isNotEmpty
                    ? ClipOval(
                        child: CachedNetworkImage(
                          imageUrl: userAvatar,
                          width: 36,
                          height: 36,
                          cacheManager: AppImageCacheManager(),
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => const Icon(Icons.person_outline, color: AppTheme.textMuted, size: 20),
                        ),
                      )
                    : const Icon(Icons.person_outline, color: AppTheme.textMuted, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: TextField(
                    controller: _commentController,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _postComment(),
                    decoration: const InputDecoration(
                      hintText: 'Viết bình luận...',
                      hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 14),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                    maxLines: null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _isPostingComment ? null : _postComment,
                child: _isPostingComment
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.gold),
                      )
                    : const Icon(Icons.send_rounded, color: AppTheme.gold, size: 22),
              ),
            ],
          ),
        ),
        const Divider(color: AppTheme.border, height: 1),
        // Comments list
        Expanded(
          child: _comments.isEmpty
              ? const Center(
                  child: Text(
                    'Chưa có bình luận nào',
                    style: TextStyle(color: AppTheme.textSub, fontSize: 14),
                  ),
                )
              : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _comments.length,
                      separatorBuilder: (_, __) => const Divider(color: AppTheme.border, height: 1),
                      itemBuilder: (context, index) {
                        final comment = _comments[index];
                        final commentUser = comment['username'] ?? comment['user'] ?? 'Người dùng';
                        final commentContent = comment['content'] ?? comment['comment'] ?? '';
                        final commentAvatar = comment['avatar']?.toString();
                        final commentTime = comment['created_at'] != null
                            ? _timeAgo(DateTime.tryParse(comment['created_at']))
                            : (comment['time'] ?? '');

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: AppTheme.bgCard,
                                child: commentAvatar != null && commentAvatar.isNotEmpty
                                    ? ClipOval(
                                        child: CachedNetworkImage(
                                          imageUrl: commentAvatar,
                                          cacheManager: AppImageCacheManager(),
                                          width: 32,
                                          height: 32,
                                          fit: BoxFit.cover,
                                          errorWidget: (_, __, ___) => const Icon(Icons.person, color: AppTheme.textMuted, size: 18),
                                        ),
                                      )
                                    : const Icon(Icons.person, color: AppTheme.textMuted, size: 18),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            commentUser,
                                            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (commentTime.isNotEmpty) ...[
                                          const SizedBox(width: 8),
                                          Text(
                                            commentTime,
                                            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      commentContent,
                                      style: const TextStyle(color: AppTheme.textSub, fontSize: 13, height: 1.4),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  // --- Actors Tab ---
  Widget _buildActorsTab() {
    if (_actors.isEmpty) {
      return const Center(
        child: Text(
          'Không có thông tin diễn viên',
          style: TextStyle(color: AppTheme.textSub, fontSize: 14),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Diễn viên',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.7,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _actors.length,
            itemBuilder: (context, index) {
              final actor = _actors[index];
              return _buildActorCard(actor);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildActorCard(Map<String, dynamic> actor) {
    return GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => ActorDetailScreen(
            name: actor['name'],
            tmdbId: actor['tmdb_id'] ?? 0,
          ),
        ));
      },
      child: Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10), bottom: Radius.circular(10)),
              child: CachedNetworkImage(
                imageUrl: actor['photo'] ?? '',
                cacheManager: AppImageCacheManager(),
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: AppTheme.bgSurface),
                errorWidget: (_, __, ___) => Container(
                  color: AppTheme.bgSurface,
                  child: const Icon(Icons.person, color: AppTheme.textMuted, size: 40),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  actor['name'] ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if ((actor['original_name'] ?? '').isNotEmpty)
                  Text(
                    actor['original_name'],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textSub,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  Future<void> _fetchActors() async {
    // ignore: avoid_print
    // ignore: avoid_print
    // ignore: avoid_print
    final castStr = _movieData?['tmdb_cast'] ?? _movieData?['actor_vi'] ?? _movieData?['actor'] ?? '';
    final castStrStr = castStr.toString();
    // ignore: avoid_print
    if (castStrStr.isEmpty) {
      // ignore: avoid_print
      return;
    }

    final names = castStrStr.split(',').map((e) => e.trim()).where((s) => s.isNotEmpty).toList();
    // ignore: avoid_print
    if (names.isEmpty) return;

    try {
      // ignore: avoid_print
      final res = await _dio.get('${AppConfig.apiUrl}/actor.php', queryParameters: {
        'batch': 'true',
        'names': names.join(','),
        'sync_missing': 'true',
      }).timeout(const Duration(seconds: 20));

      // ignore: avoid_print
      if (res.data is Map && res.data['success'] == true) {
        final actorsList = res.data['actors'] as List<dynamic>? ?? [];
        final actors = actorsList
            .where((a) => a['photo'] != null && (a['photo'] as String).isNotEmpty)
            .map<Map<String, dynamic>>((a) => {
              'name': a['name'] ?? '',
              'original_name': a['input'] ?? '',
              'photo': a['photo'] ?? '',
              'tmdb_id': a['tmdb_id'] ?? 0,
            })
            .toList();
        // ignore: avoid_print
        if (mounted) setState(() => _actors = actors);
      }
    } catch (e) {
      // ignore: avoid_print
    }
    // ignore: avoid_print
  }

  Future<void> _fetchGallery(String slug) async {
    try {
      final url = '${AppConfig.apiUrl}/gallery.php?slug=$slug';
      // ignore: avoid_print
      final res = await _dio.get(url);
      // ignore: avoid_print
      final data = res.data is String ? jsonDecode(res.data as String) : res.data;
      final images = (data['images'] as List<dynamic>? ?? [])
          .map((e) => '${AppConfig.baseUrl}$e')
          .toList();
      // ignore: avoid_print
      if (mounted && images.isNotEmpty) setState(() => _galleryImages = images);
    } catch (e) {
      // ignore: avoid_print
    }
  }

  // --- Related Tab ---
  Widget _buildRelatedTab() {
    if (_relatedMovies.isEmpty) {
      return const Center(
        child: Text(
          'Không có phim liên quan',
          style: TextStyle(color: AppTheme.textSub, fontSize: 14),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 100),
      child: MovieRail(
        title: 'Phim liên quan',
        movies: _relatedMovies,
        onMovieTap: (movie) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => MovieDetailScreen(movie: movie),
            ),
          );
        },
      ),
    );
  }
}

