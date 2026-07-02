import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/models/movie.dart';

class HeroCarousel extends StatefulWidget {
  final List<Movie> movies;
  final ValueChanged<Movie>? onMovieTap;
  final ValueChanged<int>? onPageChanged;
  final int initialPage;

  const HeroCarousel({
    super.key,
    required this.movies,
    this.onMovieTap,
    this.onPageChanged,
    this.initialPage = 0,
  });

  @override
  State<HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<HeroCarousel> {
  late final PageController _pageController;
  late int _currentPage;

  static const double _viewportFraction = 0.42;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    // Start at initialPage so first frame renders immediately,
    // then jump to offset position for infinite scroll in both directions
    _pageController = PageController(
      viewportFraction: _viewportFraction,
      initialPage: widget.initialPage,
    );
    if (widget.movies.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients) {
          final offset = widget.movies.length * 500 + widget.initialPage;
          _pageController.jumpToPage(offset);
        }
      });
    }
  }

  @override
  void didUpdateWidget(HeroCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.movies.length != widget.movies.length ||
        (oldWidget.initialPage != widget.initialPage && widget.initialPage != _currentPage)) {
      _currentPage = widget.initialPage;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients && widget.movies.isNotEmpty) {
          final offset = widget.movies.length * 500 + widget.initialPage;
          _pageController.jumpToPage(offset);
        }
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  int _realIndex(int rawIndex) {
    if (widget.movies.isEmpty) return 0;
    return rawIndex % widget.movies.length;
  }

  void _onPageChanged(int page) {
    final real = _realIndex(page);
    setState(() => _currentPage = real);
    widget.onPageChanged?.call(real);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.movies.isEmpty) return const SizedBox.shrink();

    final screenW = MediaQuery.of(context).size.width;
    final slideW = screenW * _viewportFraction;
    final slideH = slideW * 1.5;
    final sectionH = slideH + 20;

    final m = widget.movies[_currentPage];

    return Column(
      children: [
        // ── Carousel ──
        SizedBox(
          height: sectionH,
          child: PageView.builder(
              controller: _pageController,
              onPageChanged: _onPageChanged,
              itemCount: widget.movies.isEmpty ? 0 : null,
              itemBuilder: (context, index) {
                final realIdx = _realIndex(index);
                final movie = widget.movies[realIdx];
                final isActive = realIdx == _currentPage;

              return AnimatedBuilder(
                animation: _pageController,
                builder: (context, _) {
                  final pageOffset =
                      _pageController.position.haveDimensions
                          ? (_pageController.page ?? _currentPage.toDouble()) -
                              index
                          : _currentPage.toDouble() - index;

                  final scale =
                      (1.0 - pageOffset.abs() * 0.18).clamp(0.80, 1.0);
                  final rotateY = pageOffset.clamp(-1.0, 1.0) * 0.45;
                  final translateY = pageOffset.abs() * 12.0;

                  return Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.001)
                      ..rotateY(-rotateY)
                      ..scale(scale)
                      ..translate(0.0, translateY),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: GestureDetector(
                        onTap: () {
                          if (isActive) {
                            widget.onMovieTap?.call(movie);
                          } else {
                            _pageController.animateToPage(
                              index,
                              duration: const Duration(milliseconds: 350),
                              curve: Curves.easeOutCubic,
                            );
                          }
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.92),
                              width: 2,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: AspectRatio(
                              aspectRatio: 2 / 3,
                              child: CachedNetworkImage(
                                imageUrl: movie.thumbUrl ?? '',
                                fit: BoxFit.cover,
                                memCacheWidth: 600,
                                cacheKey:
                                    '${movie.slug}_${movie.id}_hero_v2',
                                placeholder: (_, __) =>
                                    Container(color: AppTheme.bgCard),
                                errorWidget: (_, __, ___) => Container(
                                  color: AppTheme.bgCard,
                                  child: const Icon(Icons.movie,
                                      color: AppTheme.textMuted),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),

        // ── Info panel ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: Column(
            children: [
              Text(
                m.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary,
                  letterSpacing: -0.2,
                ),
              ),
              if ((m.originName ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    m.originName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(fontSize: 13, color: AppTheme.textSub),
                  ),
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _HeroBtn(
                      label: _isTrailerMovie(m) ? 'Xem trailer' : 'Xem phim',
                      icon: Icons.play_arrow_rounded,
                      primary: true,
                      onTap: () => widget.onMovieTap?.call(m),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _HeroBtn(
                      label: 'Thông tin',
                      icon: Icons.info_outline,
                      primary: false,
                      onTap: () => widget.onMovieTap?.call(m),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                alignment: WrapAlignment.center,
                children: [
                  _HeroPill(
                    label:
                        'TMDB ${(m.tmdbRating ?? 0).toStringAsFixed(1)}',
                    style: PillStyle.tmdb,
                  ),
                  if ((m.ageRating ?? '').isNotEmpty)
                    _HeroPill(
                      label: _formatAgeRating(m.ageRating),
                      style: PillStyle.solid,
                    ),
                  if ((m.quality ?? '').isNotEmpty)
                    _HeroPill(
                      label: m.quality!.toUpperCase(),
                      style: PillStyle.gradient,
                    ),
                  if (m.year != null && m.year! > 0)
                    _HeroPill(
                      label: '${m.year}',
                      style: PillStyle.outline,
                    ),
                  if ((m.type ?? '').isNotEmpty && m.type != 'single')
                    _HeroPill(
                      label: _typeLabel(m.type!),
                      style: PillStyle.outline,
                    ),
                  if ((m.episodeCurrent ?? '').isNotEmpty)
                    _HeroPill(
                      label: _episodeLabel(m),
                      style: PillStyle.outline,
                    ),
                ],
              ),
              if ((m.description ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    m.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSub,
                      height: 1.55,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _typeLabel(String t) {
    switch (t) {
      case 'series':
        return 'Phim bộ';
      case 'hoathinh':
        return 'Hoạt hình';
      case 'tvshows':
        return 'TV Shows';
      default:
        return t;
    }
  }

  bool _isTrailerMovie(Movie m) {
    final ep = (m.episodeCurrent ?? '').toLowerCase();
    return ep.contains('trailer');
  }

  String _episodeLabel(Movie m) {
    final current = m.episodeCurrent ?? '';
    final total = m.episodeTotal ?? '';
    if (current.isEmpty) return '';
    if (current.toLowerCase().contains('hoàn') ||
        current.toLowerCase().contains('full')) {
      if (total.isNotEmpty) return 'Hoàn tất $total/$total';
      return 'Hoàn tất';
    }
    if (total.isNotEmpty) return '$current/$total';
    return current;
  }
}

// ── Buttons ──────────────────────────────────────────────────
class _HeroBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool primary;
  final VoidCallback? onTap;

  const _HeroBtn({
    required this.label,
    required this.icon,
    required this.primary,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          height: 38,
          decoration: BoxDecoration(
            gradient: primary
                ? const LinearGradient(
                    begin: Alignment(-0.8, -1),
                    end: Alignment(0.8, 1),
                    colors: [Color(0xFFFECF59), Color(0xFFFFF1CC)],
                  )
                : null,
            color: primary ? null : Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: primary
                ? [
                    BoxShadow(
                      color: const Color(0x1AFFDA7D),
                      blurRadius: 10,
                      spreadRadius: 5,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: const Color(0xFF1A1A1A)),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF1A1A1A),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatAgeRating(String? rating) {
  if (rating == null || rating.isEmpty) return 'P';
  final clean = rating.replaceAll(RegExp(r'^[TtPp]\.?\s*'), '');
  if (RegExp(r'^\d+$').hasMatch(clean)) return 'T.$clean';
  return rating;
}

// ── Pills ─────────────────────────────────────────────────────
enum PillStyle { tmdb, outline, solid, gradient }

class _HeroPill extends StatelessWidget {
  final String label;
  final PillStyle style;

  const _HeroPill({required this.label, this.style = PillStyle.outline});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        gradient: style == PillStyle.gradient ? const LinearGradient(
          colors: [Color(0xFEFCF559), Color(0xFFFFF1CC)],
          begin: Alignment(-0.7, 0),
          end: Alignment(1.0, 0),
        ) : null,
        color: style != PillStyle.gradient ? _bgColor : null,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _borderColor, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: _textColor,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color get _bgColor {
    switch (style) {
      case PillStyle.tmdb:
        return Colors.transparent;
      case PillStyle.outline:
        return Colors.transparent;
      case PillStyle.solid:
        return Colors.white;
      case PillStyle.gradient:
        return Colors.transparent;
    }
  }

  Color get _borderColor {
    switch (style) {
      case PillStyle.tmdb:
        return const Color(0xFFF5C518);
      case PillStyle.outline:
        return Colors.white.withValues(alpha: 0.5);
      case PillStyle.solid:
        return Colors.white;
      case PillStyle.gradient:
        return const Color(0xFEFCF559);
    }
  }

  Color get _textColor {
    switch (style) {
      case PillStyle.tmdb:
        return const Color(0xFFF5C518);
      case PillStyle.outline:
        return Colors.white;
      case PillStyle.solid:
        return Colors.black;
      case PillStyle.gradient:
        return const Color(0xFF1A1100);
    }
  }
}
