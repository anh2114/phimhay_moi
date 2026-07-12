import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/models/movie.dart';

/// Clip-path polygon — converted from exact CSS polygon in test-cards.html
/// Odd cards (1,3,5): top-right corner cut diagonally inward
/// Even cards (2,4,6): top-left corner cut diagonally (mirror)
class _TopRankClipper extends CustomClipper<Path> {
  final bool isEven;
  const _TopRankClipper({required this.isEven});

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path();

    if (!isEven) {
      // ODD: top slopes upward from left→right (cut at top-right)
      // Convert percentage polygon from CSS to absolute coordinates
      _buildPathFromPct(path, w, h, [
        94.239, 100, 5.761, 100, 5.761, 100,
        4.826, 99.95, 3.94, 99.803, 3.113, 99.569,
        2.358, 99.256, 1.687, 98.87, 1.111, 98.421,
        0.643, 97.915, 0.294, 97.362, 0.075, 96.768,
        0, 96.142, 0, 3.858, 0, 3.858,
        0.087, 3.185, 0.338, 2.552, 0.737, 1.968,
        1.269, 1.442, 1.92, 0.984, 2.672, 0.602,
        3.512, 0.306, 4.423, 0.105, 5.391, 0.008,
        6.4, 0.024, 94.879, 6.625, 94.879, 6.625,
        95.731, 6.732, 96.532, 6.919, 97.272, 7.178,
        97.942, 7.503, 98.533, 7.887, 99.038, 8.323,
        99.445, 8.805, 99.747, 9.326, 99.935, 9.88,
        100, 10.459, 100, 96.142, 100, 96.142,
        99.925, 96.768, 99.706, 97.362, 99.357, 97.915,
        98.889, 98.421, 98.313, 98.87, 97.642, 99.256,
        96.887, 99.569, 96.06, 99.803, 95.174, 99.95,
        94.239, 100,
      ]);
    } else {
      // EVEN: top slopes upward from right→left (cut at top-left, mirror)
      _buildPathFromPct(path, w, h, [
        5.761, 100, 94.239, 100, 94.239, 100,
        95.174, 99.95, 96.06, 99.803, 96.887, 99.569,
        97.642, 99.256, 98.313, 98.87, 98.889, 98.421,
        99.357, 97.915, 99.706, 97.362, 99.925, 96.768,
        100, 96.142, 100, 3.858, 100, 3.858,
        99.913, 3.185, 99.662, 2.552, 99.263, 1.968,
        98.731, 1.442, 98.08, 0.984, 97.328, 0.602,
        96.488, 0.306, 95.577, 0.105, 94.609, 0.008,
        93.6, 0.024, 5.121, 6.625, 5.121, 6.625,
        4.269, 6.732, 3.468, 6.919, 2.728, 7.178,
        2.058, 7.503, 1.467, 7.887, 0.962, 8.323,
        0.555, 8.805, 0.253, 9.326, 0.065, 9.88,
        0, 10.459, 0, 96.142, 0, 96.142,
        0.075, 96.768, 0.294, 97.362, 0.643, 97.915,
        1.111, 98.421, 1.687, 98.87, 2.358, 99.256,
        3.113, 99.569, 3.94, 99.803, 4.826, 99.95,
        5.761, 100,
      ]);
    }

    return path;
  }

  void _buildPathFromPct(Path path, double w, double h, List<double> flatPoints) {
    assert(flatPoints.length.isEven);
    path.moveTo(flatPoints[0] / 100 * w, flatPoints[1] / 100 * h);
    for (int i = 2; i < flatPoints.length; i += 2) {
      path.lineTo(flatPoints[i] / 100 * w, flatPoints[i + 1] / 100 * h);
    }
    path.close();
  }

  @override
  bool shouldReclip(covariant _TopRankClipper oldClipper) => oldClipper.isEven != isEven;
}

class TopRankCard extends StatelessWidget {
  final Movie movie;
  final int rank;
  final VoidCallback? onTap;

  const TopRankCard({
    super.key,
    required this.movie,
    this.rank = 1,
    this.onTap,
  });

  static String _shortEp(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final s = raw.trim();
    // "Hoàn Tất (30/30)" → "HT 30"
    final htMatch = RegExp(r'[Hh]oàn\s*[Tt]ất.*?(\d+)').firstMatch(s);
    if (htMatch != null) return 'HT ${htMatch.group(1)}';
    // "Full" / "full"
    if (s.toLowerCase() == 'full' || s.toLowerCase() == 'hoàn') return 'Full';
    // "Tập 12" / "Tập 12/24" → "T.12" / "T.12/24"
    final tapMatch = RegExp(r'[Tt]ập?\s*(\d+(?:/\d+)?)', caseSensitive: false).firstMatch(s);
    if (tapMatch != null) return 'T.${tapMatch.group(1)}';
    // Fallback: return as-is if short enough
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
    final isEven = rank % 2 == 0;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 132,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Poster with clip-path polygon
            ClipPath(
              clipper: _TopRankClipper(isEven: isEven),
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: Stack(
                  children: [
                    // Poster image
                    Positioned.fill(
                      child: CachedNetworkImage(
                        imageUrl: movie.thumbUrl ?? '',
                        fit: BoxFit.cover,
                        memCacheWidth: 280,
                        cacheKey: '${movie.slug}_${movie.id}_thumb',
                        placeholder: (_, __) => Container(color: AppTheme.bgSurface),
                        errorWidget: (_, __, ___) => Container(
                          color: AppTheme.bgSurface,
                          child: const Icon(Icons.movie_outlined, color: AppTheme.textMuted, size: 32),
                        ),
                      ),
                    ),
                    // Gradient mask — same clip-path
                    Positioned(
                      bottom: 0, left: 0, right: 0, top: 0,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.transparent, Color(0xCC191B24)],
                            stops: [0.0, 0.55, 1.0],
                          ),
                        ),
                      ),
                    ),
                    // Episode + Language badges — bottom center
                    Positioned(
                      bottom: 10, left: 0, right: 0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Episode badge — solid white bg
                          if (_shortEp(movie.episodeCurrent).isNotEmpty)
                            _RankBadge(
                              label: _shortEp(movie.episodeCurrent!),
                              bgColor: Colors.white,
                              textColor: const Color(0xFF1A1100),
                              borderColor: Colors.transparent,
                            ),
                          // TM badge — green bg
                          if (_shortLang(movie.lang).isNotEmpty && _isThuyetMinh(movie.lang)) ...[
                            const SizedBox(width: 4),
                            _RankBadge(
                              label: _shortLang(movie.lang!),
                              bgColor: const Color(0xFF10B981),
                              textColor: Colors.white,
                              borderColor: Colors.transparent,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Rank number + Title
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Rank number — large italic gold
                Text(
                  '$rank',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    color: Color(0xFFFFD875),
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                    height: 1,
                  ),
                ),
                const SizedBox(width: 6),
                // Title + origin
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        movie.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                        ),
                      ),
                      if ((movie.originName ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            movie.originName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Color(0xFF777E90), fontSize: 10),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RankBadge extends StatelessWidget {
  final String label;
  final Color bgColor;
  final Color textColor;
  final Color borderColor;

  const _RankBadge({
    required this.label,
    required this.bgColor,
    required this.textColor,
    this.borderColor = Colors.transparent,
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
