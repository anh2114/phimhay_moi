import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/providers/player_provider.dart';
import 'package:phimhay_app/screens/watch/watch_screen.dart';

/// Persistent mini-player overlay — lives at App root level
/// Shows when video is minimized, allows browsing other screens
class MiniPlayerOverlay extends StatelessWidget {
  const MiniPlayerOverlay({super.key});

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        if (!player.isMiniPlayerMode || !player.hasActivePlayer || player.player == null) {
          return const SizedBox.shrink();
        }

        final currentPos = Duration(seconds: player.currentPosition);
        final currentDur = Duration(seconds: player.currentDuration);
        final progress = player.currentDuration > 0
            ? player.currentPosition / player.currentDuration
            : 0.0;
        final epClean = player.epName.replaceAll(RegExp(r'^[Tt]ậ?p?\s*', caseSensitive: false), '').trim();

        return Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: GestureDetector(
            onTap: () {
              // ★ FIX: Remove Video widget TRƯỚC khi push WatchScreen
              //.exitMiniPlayer → rebuild → Video removed → then push
              final movieId = player.movieId;
              final epId = player.episodeId;
              final serverIdx = player.serverIdx;
              final slug = player.movieSlug;
              final title = player.movieTitle;
              final pos = player.currentPosition;
              player.exitMiniPlayer();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => WatchScreen(
                        movieId: movieId,
                        episodeId: epId,
                        serverIdx: serverIdx,
                        movieSlug: slug,
                        movieTitle: title,
                        initialPosition: pos,
                      ),
                    ),
                  );
                }
              });
            },
            onVerticalDragEnd: (details) {
              if (details.velocity.pixelsPerSecond.dy < -300) {
                final movieId = player.movieId;
                final epId = player.episodeId;
                final serverIdx = player.serverIdx;
                final slug = player.movieSlug;
                final title = player.movieTitle;
                final pos = player.currentPosition;
                player.exitMiniPlayer();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => WatchScreen(
                          movieId: movieId,
                          episodeId: epId,
                          serverIdx: serverIdx,
                          movieSlug: slug,
                          movieTitle: title,
                          initialPosition: pos,
                        ),
                      ),
                    );
                  }
                });
              }
            },
            child: Container(
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1C21),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 12,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Progress bar
                  SizedBox(
                    height: 2,
                    child: LinearProgressIndicator(
                      value: progress.clamp(0.0, 1.0),
                      backgroundColor: Colors.white.withValues(alpha: 0.15),
                      valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.accent),
                    ),
                  ),
                  // Content
                  Expanded(
                    child: Row(
                      children: [
                        // Video thumbnail (live)
                        if (player.videoController != null)
                          SizedBox(
                            width: 142,
                            height: 78,
                            child: Video(
                              controller: player.videoController!,
                              controls: NoVideoControls,
                            ),
                          )
                        else
                          Container(
                            width: 142,
                            height: 78,
                            color: Colors.black,
                            child: const Icon(Icons.play_circle_outline, color: Colors.white38, size: 32),
                          ),
                        // Title + controls
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  player.movieTitle,
                                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Tập $epClean  •  ${_formatDuration(currentPos)} / ${_formatDuration(currentDur)}',
                                  style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 10),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    GestureDetector(
                                      onTap: () => player.togglePlayPause(),
                                      child: Icon(
                                        player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                        color: Colors.white,
                                        size: 24,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    const Icon(Icons.fullscreen_rounded, color: Colors.white70, size: 20),
                                    const Spacer(),
                                    GestureDetector(
                                      onTap: () => player.closeMiniPlayer(),
                                      child: const Icon(Icons.close_rounded, color: Colors.white38, size: 18),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
