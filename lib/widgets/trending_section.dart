import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/services/image_cache_manager.dart';
import 'package:phimhay_app/services/tmdb_service.dart';

class TrendingSection extends StatefulWidget {
  final String title;
  final String timeWindow;
  final int limit;
  final Function(TmdbMovie)? onMovieTap;

  const TrendingSection({
    super.key,
    required this.title,
    this.timeWindow = 'day',
    this.limit = 10,
    this.onMovieTap,
  });

  @override
  State<TrendingSection> createState() => _TrendingSectionState();
}

class _TrendingSectionState extends State<TrendingSection> {
  final TmdbService _tmdbService = TmdbService();
  List<TmdbMovie> _movies = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchTrending();
  }

  Future<void> _fetchTrending() async {
    final movies = await _tmdbService.fetchTrending(
      timeWindow: widget.timeWindow,
      limit: widget.limit,
    );
    if (mounted) {
      setState(() {
        _movies = movies;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox(
        height: 280,
        child: Center(child: CircularProgressIndicator(color: AppTheme.accent)),
      );
    }
    if (_movies.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 10),
      padding: const EdgeInsets.only(top: 16, bottom: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF1A2235),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              widget.title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Horizontal scrollable list
          SizedBox(
            height: 260,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _movies.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                return _TrendingCard(
                  movie: _movies[index],
                  rank: index + 1,
                  onTap: () => widget.onMovieTap?.call(_movies[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendingCard extends StatelessWidget {
  final TmdbMovie movie;
  final int rank;
  final VoidCallback? onTap;

  const _TrendingCard({
    required this.movie,
    required this.rank,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Poster with white border (giống hero carousel)
            Expanded(
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
                  child: Stack(
                    children: [
                      // Poster image
                      Positioned.fill(
                        child: CachedNetworkImage(
                          imageUrl: movie.posterUrl,
                          fit: BoxFit.cover,
                          cacheManager: AppImageCacheManager(),
                          fadeInDuration: const Duration(milliseconds: 200),
                          placeholder: (_, __) => Container(
                            color: AppTheme.bgSurface,
                            child: const Icon(Icons.movie, color: AppTheme.textMuted, size: 32),
                          ),
                          errorWidget: (_, __, ___) => Container(
                            color: AppTheme.bgSurface,
                            child: const Icon(Icons.movie, color: AppTheme.textMuted, size: 32),
                          ),
                        ),
                      ),
                      // Gradient overlay
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: 60,
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Color(0xCC000000)],
                            ),
                          ),
                        ),
                      ),
                      // Rank number (golden)
                      Positioned(
                        bottom: 4,
                        left: 8,
                        child: Text(
                          '$rank',
                          style: const TextStyle(
                            color: Color(0xFFF5C84C),
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                            height: 1,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 2)),
                            ],
                          ),
                        ),
                      ),
                      // IMDB rating (transparent + golden border)
                      if (movie.voteAverage > 0)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: const Color(0xFFF5C84C),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              'IMDB ${movie.voteAverage.toStringAsFixed(1)}',
                              style: const TextStyle(
                                color: Color(0xFFF5C84C),
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Title
            Text(
              movie.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            // Original title
            if (movie.originalTitle != movie.title)
              Text(
                movie.originalTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 11,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
