import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/services/player_holder.dart';
import 'package:phimhay_app/screens/watch/watch_screen.dart';

/// Persistent mini-player overlay at App root level
/// Shows Home/Search content behind + mini-player bar at bottom
class MiniPlayerOverlay extends StatefulWidget {
  const MiniPlayerOverlay({super.key});

  @override
  State<MiniPlayerOverlay> createState() => _MiniPlayerOverlayState();
}

class _MiniPlayerOverlayState extends State<MiniPlayerOverlay> {
  @override
  void initState() {
    super.initState();
    PlayerHolder.startPolling(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    PlayerHolder.stopPolling();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _goToFullscreen() {
    if (!PlayerHolder.isActive || PlayerHolder.player == null) return;

    final movieId = PlayerHolder.movieId;
    final epId = PlayerHolder.episodeId;
    final sIdx = PlayerHolder.serverIdx;
    final slug = PlayerHolder.movieSlug;
    final title = PlayerHolder.movieTitle;
    final pos = PlayerHolder.currentPosition;

    PlayerHolder.isMiniPlayerMode = false;
    PlayerHolder.isInWatchScreen = true;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WatchScreen(
          movieId: movieId,
          episodeId: epId,
          serverIdx: sIdx,
          movieSlug: slug,
          movieTitle: title,
          initialPosition: pos,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!PlayerHolder.isActive || !PlayerHolder.isMiniPlayerMode || PlayerHolder.player == null) {
      return const SizedBox.shrink();
    }

    // Don't render Video if WatchScreen has it
    if (PlayerHolder.isInWatchScreen) return const SizedBox.shrink();

    final videoCtrl = PlayerHolder.videoController;
    final pos = Duration(seconds: PlayerHolder.currentPosition);
    final dur = Duration(seconds: PlayerHolder.currentDuration);
    final progress = PlayerHolder.currentDuration > 0
        ? PlayerHolder.currentPosition / PlayerHolder.currentDuration
        : 0.0;
    final epClean = PlayerHolder.epName.replaceAll(RegExp(r'^[Tt]ậ?p?\s*', caseSensitive: false), '').trim();

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: GestureDetector(
        onTap: _goToFullscreen,
        onVerticalDragEnd: (details) {
          if (details.velocity.pixelsPerSecond.dy < -300) _goToFullscreen();
        },
        child: Container(
          height: 80,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1C21),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 12, offset: const Offset(0, -4))],
          ),
          child: Column(
            children: [
              SizedBox(
                height: 2,
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  backgroundColor: Colors.white.withValues(alpha: 0.15),
                  valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.accent),
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    if (videoCtrl != null)
                      SizedBox(
                        width: 142, height: 78,
                        child: Video(controller: videoCtrl, key: const ValueKey('mini_overlay'), controls: NoVideoControls),
                      )
                    else
                      Container(width: 142, height: 78, color: Colors.black),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(PlayerHolder.movieTitle, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 2),
                            Text('Tập $epClean  •  ${_formatDuration(pos)} / ${_formatDuration(dur)}', style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            Row(children: [
                              GestureDetector(
                                onTap: () {
                                  if (PlayerHolder.isPlaying) {
                                    PlayerHolder.player?.pause();
                                  } else {
                                    PlayerHolder.player?.play();
                                  }
                                },
                                child: Icon(PlayerHolder.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 24),
                              ),
                              const SizedBox(width: 12),
                              GestureDetector(
                                onTap: _goToFullscreen,
                                child: const Icon(Icons.fullscreen_rounded, color: Colors.white70, size: 20),
                              ),
                              const Spacer(),
                              GestureDetector(
                                onTap: () {
                                  PlayerHolder.player?.dispose();
                                  PlayerHolder.clear();
                                },
                                child: const Icon(Icons.close_rounded, color: Colors.white38, size: 18),
                              ),
                            ]),
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
  }
}
