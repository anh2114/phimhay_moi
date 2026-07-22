import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../../config/app_config.dart';
import '../../config/theme.dart';
import '../../models/movie.dart';
import '../../providers/home_provider.dart';
import '../../providers/watch_history_provider.dart';
import '../../services/image_cache_manager.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/header.dart';
import '../../widgets/hero_carousel.dart';
import '../../widgets/movie_rail.dart';
import '../../widgets/chips.dart';
import '../../widgets/bottom_nav.dart';
import '../../widgets/shimmer_loading.dart';
import '../movie_detail/movie_detail_screen.dart';
import '../search/search_screen.dart';
import '../watch/watch_screen.dart';
import '../list/list_screen.dart';
import '../schedule/schedule_screen.dart';
import '../profile/profile_screen.dart';
import '../watch_party/watch_party_screen.dart';
import '../notification/notification_screen.dart';
import '../actors/actors_list_screen.dart';
import '../../widgets/collection_carousel.dart';
import '../../widgets/smart_link_ad.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class HomeScreen extends StatefulWidget {
  final int initialIndex;
  const HomeScreen({super.key, this.initialIndex = 0});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _navIndex;
  String _selectedChip = 'Đề xuất';
  final ScrollController _scrollController = ScrollController();
  int _heroCurrentPage = 0;
  double _headerOpacity = 0.0;

  @override
  void initState() {
    super.initState();
    _navIndex = widget.initialIndex;
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<HomeProvider>().fetchHome();
      context.read<WatchHistoryProvider>().fetchContinueWatching();
    });
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    // Fade in from 0 to 150px scroll
    final opacity = (offset / 150.0).clamp(0.0, 1.0);
    if (opacity != _headerOpacity) {
      setState(() => _headerOpacity = opacity);
    }
  }

  /// Convert chip name → API filter param
  String _chipToFilter(String chip) {
    switch (chip) {
      case 'Phim bộ': return 'phim-bo';
      case 'Phim lẻ': return 'phim-le';
      case 'Thể loại ▾': return 'the-loai';
      default: return 'all'; // Đề xuất
    }
  }

  /// Gọi lại API khi đổi chip — giữ nguyên vị trí scroll
  void _onChipSelected(String chip) {
    if (chip == _selectedChip) return;
    setState(() => _selectedChip = chip);
    context.read<HomeProvider>().fetchHome(filter: _chipToFilter(chip));
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onMovieTap(Movie movie) {
    SmartLinkAd.show(context, onComplete: () {
      Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          reverseTransitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (_, __, ___) => MovieDetailScreen(movie: movie),
          transitionsBuilder: (_, animation, __, child) {
            return FadeTransition(
              opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
              child: child,
            );
          },
        ),
      );
    });
  }

  void _onContinueWatchingTap(WatchHistoryMovie cw) {
    SmartLinkAd.show(context, onComplete: () {
      _showContinueWatchingPopup(cw);
    });
  }

  void _showContinueWatchingPopup(WatchHistoryMovie cw) {
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 32),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E2026),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.6),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Poster + gradient overlay
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  child: Stack(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        height: 140,
                        child: CachedNetworkImage(
                          imageUrl: cw.posterUrl,
                          fit: BoxFit.cover,
                          cacheManager: AppImageCacheManager(),
                          errorWidget: (_, __, ___) => CachedNetworkImage(
                            imageUrl: cw.thumbUrl,
                            fit: BoxFit.cover,
                            cacheManager: AppImageCacheManager(),
                            errorWidget: (_, __, ___) => Container(
                              color: AppTheme.bgSurface,
                              child: const Icon(Icons.movie, color: AppTheme.textMuted, size: 48),
                            ),
                          ),
                        ),
                      ),
                      // Gradient overlay
                      Positioned.fill(
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Color(0xFF1E2026)],
                              stops: [0.4, 1.0],
                            ),
                          ),
                        ),
                      ),
                      // Title at bottom of poster
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 12,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cw.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Text(
                                  'Tập ${cw.episodeDisplay}',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.6),
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  width: 4,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: AppTheme.accent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  cw.timeDisplay,
                                  style: const TextStyle(
                                    color: AppTheme.accent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // Buttons
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                  child: Row(
                    children: [
                      // Xem thông tin phim
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            Navigator.of(dialogContext).pop();
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => MovieDetailScreen(movie: cw.toMovie()),
                              ),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.15),
                              ),
                            ),
                            child: const Center(
                              child: Text(
                                'Xem thông tin phim',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Xem trực tiếp
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            Navigator.of(dialogContext).pop();
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => WatchScreen(
                                  movieId: cw.movieId,
                                  episodeId: cw.episodeId > 0 ? cw.episodeId : 1,
                                  serverIdx: cw.serverIdx,
                                  movieSlug: cw.slug,
                                  movieTitle: cw.name,
                                  initialPosition: cw.position,
                                ),
                              ),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5E6B8),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.play_arrow_rounded, color: Color(0xFF1A1100), size: 20),
                                SizedBox(width: 6),
                                Text(
                                  'Xem trực tiếp',
                                  style: TextStyle(
                                    color: Color(0xFF1A1100),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _onNavSelected(int index) {
    if (index == _navIndex) {
      // Tab dang active → scroll to top
      if (_scrollController.hasClients) {
        _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
      if (index == 0) {
        context.read<HomeProvider>().invalidateCache();
        context.read<HomeProvider>().fetchHome(filter: _chipToFilter(_selectedChip), forceRefresh: true);
      }
      return;
    }
    // ★ Smart link ad khi chuyển tab
    SmartLinkAd.show(context, onComplete: () {
      setState(() => _navIndex = index);
    });
  }

  void _onMoreTap(String href, String title) {
    // Phân tích href: /danh-sach/phim-moi, /the-loai/hanh-dong, /quoc-gia/han-quoc
    final parts = href.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) return;

    final category = parts[0]; // danh-sach, the-loai, quoc-gia
    final slug = parts[1];

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ListScreen(
          type: category == 'danh-sach' ? slug : category,
          title: title,
          genre: category == 'the-loai' ? slug : null,
          country: category == 'quoc-gia' ? slug : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Stack(
        children: [
          // Glow background — chỉ hiện khi ở tab Home và scroll chưa quá mức
          if (_navIndex == 0 && _headerOpacity < 0.3)
            Positioned.fill(
              child: Opacity(
                opacity: (1.0 - _headerOpacity / 0.3).clamp(0.0, 1.0),
                child: _buildGlowBackground(),
              ),
            ),
          // Nội dung tab — padding tránh Header & BottomNav
          Padding(
            padding: EdgeInsets.only(
              top: topPad + 56,
            ),
            child: IndexedStack(
              index: _navIndex,
              children: [
                _buildHomeTab(),
                const SearchScreen(isTab: true),
                const ScheduleScreen(isTab: true),
                const ProfileScreen(isTab: true),
              ],
            ),
          ),
          // Header cố định
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Header(
              backgroundOpacity: _headerOpacity,
              onSearchTap: () => setState(() => _navIndex = 1),
              onWatchPartyTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const WatchPartyScreen()),
                );
              },
              onNotificationTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const NotificationScreen()),
                );
              },
              onActorsTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ActorsListScreen()),
                );
              },
              onAccountTap: () => setState(() => _navIndex = 3),
            ),
          ),
          // BottomNav thường — không zoom
          Align(
            alignment: Alignment.bottomCenter,
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

  Widget _buildHomeTab() {
    return Consumer<HomeProvider>(builder: (context, provider, _) {
      if (provider.isLoading && provider.heroMovies.isEmpty) {
        return ListView(
          children: const [
            SizedBox(height: 12),
            ShimmerHeroCarousel(),
            SizedBox(height: 8),
            ShimmerMovieRail(),
            ShimmerMovieRail(),
          ],
        );
      }
      if (provider.error != null && provider.heroMovies.isEmpty) {
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, size: 48, color: AppTheme.textMuted),
            const SizedBox(height: 16),
            Text('Lỗi: ${provider.error}', style: const TextStyle(color: AppTheme.textSub)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: () => provider.fetchHome(), child: const Text('Thử lại')),
          ]),
        );
      }
      return RefreshIndicator(
        onRefresh: () {
          provider.invalidateCache();
          return provider.fetchHome(filter: provider.currentFilter, forceRefresh: true);
        },
        color: AppTheme.accent,
        child: ListView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            // Hero section: blur background + chips + carousel
            _buildHeroSection(provider),
            // Continue Watching
            _buildContinueWatching(),
            // Collection carousel
            const CollectionCarousel(),
            ...provider.sections.map((s) => MovieRail(
              title: s.title,
              moreHref: s.moreHref,
              movies: s.movies,
              showRank: true,
              onMovieTap: _onMovieTap,
              onMoreTap: (href) => _onMoreTap(href, s.title),
            )),
            const SizedBox(height: 80), // Spacer cho BottomNav
          ],
        ),
      );
    });
  }

  Widget _buildGlowBackground() {
    return Consumer<HomeProvider>(builder: (context, provider, _) {
      if (provider.heroMovies.isEmpty) return const SizedBox.shrink();
      final movie = provider.heroMovies[_heroCurrentPage.clamp(0, provider.heroMovies.length - 1)];
      return Stack(
        clipBehavior: Clip.none,
        children: [
          // Blurred poster glow — tràn lên navbar
          Positioned(
            top: -80,
            left: -40,
            right: -40,
            height: 800,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: Opacity(
                opacity: 0.6,
                child: CachedNetworkImage(
                  imageUrl: movie.thumbUrl ?? '',
                  fit: BoxFit.cover,
                  cacheManager: AppImageCacheManager(),
                  cacheKey: '${movie.slug}_${movie.id}_glow',
                  fadeInDuration: Duration.zero,
                  placeholder: (_, __) => const SizedBox.shrink(),
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          // Radial warm glow
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 350,
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 0.8,
                  colors: [
                    AppTheme.accent.withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildHeroSection(HomeProvider provider) {
    if (provider.heroMovies.isEmpty) return const SizedBox.shrink();
    final topPad = MediaQuery.of(context).padding.top;
    final blurTop = -(topPad + 56);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Gradient fade — blur tự nhiên mờ xuống
        Positioned(
          top: blurTop + 380,
          left: 0,
          right: 0,
          bottom: -200,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  AppTheme.bg,
                  AppTheme.bg,
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ),
        // Chips + Carousel
        Column(
          children: [
            const SizedBox(height: 4),
            Chips(selectedChip: _selectedChip, onChipSelected: _onChipSelected),
            const SizedBox(height: 12),
            HeroCarousel(
              movies: provider.heroMovies,
              onMovieTap: _onMovieTap,
              onPageChanged: (page) => setState(() => _heroCurrentPage = page),
              initialPage: _heroCurrentPage,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildContinueWatching() {
    return Consumer<WatchHistoryProvider>(
      builder: (context, watchProvider, _) {
        if (watchProvider.isLoadingContinue) {
          return const SizedBox(height: 300, child: Center(child: CircularProgressIndicator(color: AppTheme.accent)));
        }
        if (watchProvider.continueWatching.isEmpty) {
          return const SizedBox.shrink();
        }
        final items = watchProvider.continueWatching;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Xem tiếp của bạn',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 310,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 14),
                itemBuilder: (context, index) {
                  final cw = items[index];
                  return _ContinueWatchingCard(
                    item: cw,
                    onTap: () => _onContinueWatchingTap(cw),
                    onRemove: () => watchProvider.removeFromHistory(cw.movieId),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ContinueWatchingCard extends StatelessWidget {
  final WatchHistoryMovie item;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _ContinueWatchingCard({
    required this.item,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 160,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Poster area (portrait, fills most of card)
            Expanded(
              child: Stack(
                children: [
                  // Poster image - rounded corners
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: CachedNetworkImage(
                        imageUrl: item.thumbUrl,
                        fit: BoxFit.cover,
                        cacheManager: AppImageCacheManager(),
                        fadeInDuration: const Duration(milliseconds: 200),
                        fadeOutDuration: const Duration(milliseconds: 100),
                        placeholder: (_, __) => Container(color: AppTheme.bgSurface),
                        errorWidget: (_, __, ___) => Container(
                          color: AppTheme.bgSurface,
                          child: const Icon(Icons.movie, color: AppTheme.textMuted, size: 40),
                        ),
                      ),
                    ),
                  ),
                  // Gradient overlay ở dưới để text đọc được
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 80,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.7),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Close button (top-right)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: GestureDetector(
                      onTap: onRemove,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: const Icon(Icons.close, color: Colors.white, size: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: item.progress / 100.0,
                backgroundColor: AppTheme.bgSurface,
                valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.accent),
                minHeight: 3,
              ),
            ),
            const SizedBox(height: 6),
            // Episode + time
            Text(
              'Tập ${item.episodeDisplay} • ${item.timeDisplay}',
              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            // Movie name
            Text(
              item.name,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (item.originName.isNotEmpty)
              Text(
                item.originName,
                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }
}
