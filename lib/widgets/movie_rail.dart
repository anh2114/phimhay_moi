import 'package:flutter/material.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/models/movie.dart';
import 'package:phimhay_app/widgets/movie_card.dart';
import 'package:phimhay_app/widgets/top_rank_card.dart';
import 'package:phimhay_app/widgets/native_ad_card.dart';
import 'package:phimhay_app/services/startapp_ad_service.dart';

class MovieRail extends StatefulWidget {
  final String title;
  final String? moreHref;
  final List<Movie> movies;
  final bool showRank;
  final ValueChanged<Movie>? onMovieTap;
  final ValueChanged<String>? onMoreTap;

  const MovieRail({
    super.key,
    required this.title,
    this.moreHref,
    required this.movies,
    this.showRank = false,
    this.onMovieTap,
    this.onMoreTap,
  });

  @override
  State<MovieRail> createState() => _MovieRailState();
}

class _MovieRailState extends State<MovieRail> {
  late final String _adTag;

  @override
  void initState() {
    super.initState();
    _adTag = 'rail_${widget.title.hashCode}';
    if (widget.movies.length > 5) {
      StartAppAdService.loadNativeAd(_adTag);
    }
  }

  @override
  void dispose() {
    StartAppAdService.disposeNativeAd(_adTag);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.movies.isEmpty) return const SizedBox.shrink();

    final nativeAd = StartAppAdService.getNativeAd(_adTag);
    final hasNative = nativeAd != null && widget.movies.length > 5;
    final totalItems = widget.movies.length + (hasNative ? 1 : 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
              if (widget.moreHref != null)
                GestureDetector(
                  onTap: () => widget.onMoreTap?.call(widget.moreHref!),
                  child: const Text(
                    'Xem tất cả →',
                    style: TextStyle(
                      color: AppTheme.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: widget.showRank
              ? 132 * 1.5 + 8 + 50 + 14
              : 132 * 1.5 + 8 + 34 + 14,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            physics: const BouncingScrollPhysics(),
            itemCount: totalItems,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              if (hasNative && index == 5) {
                return NativeAdCard(nativeAd: nativeAd);
              }
              final movieIndex = hasNative && index > 5 ? index - 1 : index;
              final movie = widget.movies[movieIndex];
              if (widget.showRank) {
                return TopRankCard(
                  movie: movie,
                  rank: movieIndex + 1,
                  onTap: () => widget.onMovieTap?.call(movie),
                );
              }
              return MovieCard(
                movie: movie,
                rank: 0,
                onTap: () => widget.onMovieTap?.call(movie),
              );
            },
          ),
        ),
      ],
    );
  }
}
