import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/services/image_cache_manager.dart';
import 'package:phimhay_app/services/tmdb_service.dart';

class TrendingSection extends StatefulWidget {
  final String title;
  final String timeWindow; // 'day' or 'week'
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
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
          // Poster container
          Expanded(
            child: Stack(
              children: [
                // Poster image
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
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
                ),
                // Gradient overlay at bottom
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 60,
                  child: Container(
                    decoration: const BoxDecoration(
                      borderRadius: BorderRadius.vertical(bottom: Radius.circular(10)),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xCC000000)],
                      ),
                    ),
                  ),
                ),
                // Rank number (large, bottom-left)
                Positioned(
                  bottom: 4,
                  left: 8,
                  child: Text(
                    '$rank',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      height: 1,
                      shadows: [
                        Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 2)),
                      ],
                    ),
                  ),
                ),
                // Rating badge (top-right)
                if (movie.voteAverage > 0)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.star, color: Color(0xFFF5C518), size: 12),
                          const SizedBox(width: 2),
                          Text(
                            movie.voteAverage.toStringAsFixed(1),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
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
    );
    }
}
