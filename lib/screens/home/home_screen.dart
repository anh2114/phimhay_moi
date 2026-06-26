import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../../config/theme.dart';
import '../../models/movie.dart';
import '../../providers/home_provider.dart';
import '../../providers/watch_history_provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/header.dart';
import '../../widgets/hero_carousel.dart';
import '../../widgets/movie_rail.dart';
import '../../widgets/chips.dart';
import '../../widgets/bottom_nav.dart';
import '../../widgets/shimmer_loading.dart';
import '../movie_detail/movie_detail_screen.dart';
import '../search/search_screen.dart';
import '../list/list_screen.dart';
import '../schedule/schedule_screen.dart';
import '../profile/profile_screen.dart';
import '../watch_party/watch_party_screen.dart';
import '../notification/notification_screen.dart';
import '../actors/actors_list_screen.dart';
import '../../services/unity_ad_service.dart';

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

  @override
  void initState() {
    super.initState();
    _navIndex = widget.initialIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<HomeProvider>().fetchHome();
    });

    // Pre-load interstitial ad — khi user duyệt home 5-10s thì ad đã ready
    UnityAdService.init();
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
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MovieDetailScreen(movie: movie)),
    );
  }

  void _onNavSelected(int index) {
    if (index == _navIndex) {
      // Tab dang active → scroll to top
      if (_scrollController.hasClients) {
        _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
      // Home tab thi reload
      if (index == 0) {
        context.read<HomeProvider>().invalidateCache();
        context.read<HomeProvider>().fetchHome(filter: _chipToFilter(_selectedChip), forceRefresh: true);
      }
      return;
    }
    setState(() => _navIndex = index);
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
                  avatarUrl: auth.isLoggedIn ? (auth.user?['avatar']?.toString()) : null,
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

  Widget _buildHeroSection(HomeProvider provider) {
    if (provider.heroMovies.isEmpty) return const SizedBox.shrink();
    final topPad = MediaQuery.of(context).padding.top;
    final movie = provider.heroMovies[_heroCurrentPage.clamp(0, provider.heroMovies.length - 1)];
    final blurTop = -(topPad + 56);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Blurred poster glow - tràn lên navbar
        Positioned(
          top: blurTop,
          left: -40,
          right: -40,
          height: 700,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
            child: Opacity(
              opacity: 0.6,
              child: CachedNetworkImage(
                imageUrl: (movie.thumbUrl?.isNotEmpty == true)
                    ? movie.thumbUrl!
                    : (movie.posterUrl ?? ''),
                fit: BoxFit.cover,
                memCacheWidth: 400,
                cacheKey: '${movie.slug}_${movie.id}_glow',
                placeholder: (_, __) => const SizedBox.shrink(),
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
        // Radial warm glow
        Positioned(
          top: blurTop + 80,
          left: 0,
          right: 0,
          height: 300,
          child: Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 0.8,
                colors: [
                  AppTheme.accent.withValues(alpha: 0.1),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        // Gradient fade — blur tự nhiên mờ xuống, gradient nhẹ ở mép dưới
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
}
