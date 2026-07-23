import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/models/movie.dart';
import 'package:phimhay_app/services/image_cache_manager.dart';

class MovieCard extends StatelessWidget {
  final Movie movie;
  final int rank;
  final int index; // Index trong list (0-based) — dùng để alternate vị trí badge TM
  final VoidCallback? onTap;

  const MovieCard({
    super.key,
    required this.movie,
    this.rank = 0,
    this.index = 0,
    this.onTap,
  });

  static String _shortEp(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final s = raw.trim();
    final htMatch = RegExp(r'[Hh]oàn\s*[Tt]ất.*?(\d+)').firstMatch(s);
    if (htMatch != null) return 'HT ${htMatch.group(1)}';
    if (s.toLowerCase() == 'full' || s.toLowerCase() == 'hoàn') return 'Full';
    final tapMatch = RegExp(r'[Tt]ập?\s*(\d+(?:/\d+)?)', caseSensitive: false).firstMatch(s);
    if (tapMatch != null) return 'T.${tapMatch.group(1)}';
    return s.length <= 10 ? s : s.substring(0, 10);
  }

  static String _shortLang(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final s = raw.toLowerCase();
    if (s.contains('vietsub') || s.contains('phụ đề') || s.contains('sub')) return 'PĐ';
    if (s.contains('thuyết minh') || s.contains('lồng tiếng') || s.contains('tm') || s.contains('lt')) return 'TM';
    return raw;
  }

  static bool _isVietsub(String? raw) {
    if (raw == null) return false;
    final s = raw.toLowerCase();
    return s.contains('vietsub') || s.contains('phụ đề') || s.contains('sub');
  }

  static bool _isThuyetMinh(String? raw) {
    if (raw == null) return false;
    final s = raw.toLowerCase();
    return s.contains('thuyết minh') || s.contains('lồng tiếng') || s.contains('tm') || s.contains('lt');
  }

  /// Quality badge label: HD, FHD, 4K, etc.
  static String _qualityBadge(String? quality) {
    if (quality == null || quality.isEmpty) return '';
    final q = quality.toUpperCase().trim();
    if (q.contains('4K') || q.contains('2160')) return '4K';
    if (q.contains('FHD') || q.contains('1080')) return 'FHD';
    if (q.contains('HD') || q.contains('720')) return 'HD';
    if (q.contains('SD') || q.contains('480')) return 'SD';
    return q.length <= 6 ? q : q.substring(0, 6);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        // .m-movie-card: width 132px
        width: 132,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Poster container — .m-movie-poster-wrap
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: AppTheme.bgSurface,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  children: [
                    // Poster image — aspect-ratio: 2/3
                    AspectRatio(
                      aspectRatio: 2 / 3,
                      child: CachedNetworkImage(
                        imageUrl: movie.thumbUrl ?? '',
                        fit: BoxFit.cover,
                        cacheManager: AppImageCacheManager(),
                        cacheKey: '${movie.slug}_${movie.id}_thumb',
                        memCacheWidth: 280,
                        fadeInDuration: const Duration(milliseconds: 200),
                        fadeOutDuration: const Duration(milliseconds: 100),
                        placeholder: (_, __) => Container(color: AppTheme.bgSurface),
                        errorWidget: (_, __, ___) => Container(
                          color: AppTheme.bgSurface,
                          child: const Icon(Icons.movie_outlined, color: AppTheme.textMuted, size: 32),
                        ),
                      ),
                    ),
                    // Gradient scrim — .m-movie-poster-wrap::after
                    Positioned(
                      bottom: 0, left: 0, right: 0,
                      child: Container(
                        height: 72,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Color(0x99000000)],
                          ),
                        ),
                      ),
                    ),
                    // Rank badge — .m-movie-rank (top-left)
                    if (rank > 0)
                      Positioned(
                        top: 6, left: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.accent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '$rank',
                            style: const TextStyle(color: Color(0xFF1A1100), fontSize: 12, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                    // Quality + TM + Episode badges — bottom left
                    Positioned(
                      bottom: 7, left: 7,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Quality — white bg, black text
                          if (_qualityBadge(movie.quality).isNotEmpty)
                            _BadgeChip(
                              label: _qualityBadge(movie.quality),
                              bgColor: Colors.white,
                              textColor: const Color(0xFF1A1100),
                              borderColor: Colors.transparent,
                            ),
                          if (_qualityBadge(movie.quality).isNotEmpty)
                            const SizedBox(width: 4),
                          // TM — golden gradient (same as Xem phim button)
                          if (_isThuyetMinh(movie.lang))
                            _BadgeChip(
                              label: 'TM',
                              bgColor: const Color(0xFFFECF59),
                              textColor: const Color(0xFF1A1100),
                              borderColor: Colors.transparent,
                            ),
                          if (_isThuyetMinh(movie.lang) && _shortEp(movie.episodeCurrent).isNotEmpty)
                            const SizedBox(width: 4),
                          // Episode — green bg, white text
                          if (_shortEp(movie.episodeCurrent).isNotEmpty)
                            _BadgeChip(
                              label: _shortEp(movie.episodeCurrent!),
                              bgColor: const Color(0xFF10B981),
                              textColor: Colors.white,
                              borderColor: Colors.transparent,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Title — .m-movie-name
            Text(
              movie.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
            ),
            // Origin name — .m-movie-origin
            if ((movie.originName ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  movie.originName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BadgeChip extends StatelessWidget {
  final String label;
  final Color bgColor;
  final Color textColor;
  final Color borderColor;

  const _BadgeChip({
    required this.label,
    required this.bgColor,
    required this.textColor,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
        border: borderColor != Colors.transparent
            ? Border.all(color: borderColor, width: 1)
            : null,
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          height: 1.2,
          shadows: const [
            Shadow(color: Colors.black54, blurRadius: 2, offset: Offset(0, 1)),
          ],
        ),
      ),
    );
  }
}
