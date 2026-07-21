import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/services/player_holder.dart';
import 'package:phimhay_app/services/movie_service.dart';
import 'package:phimhay_app/screens/watch/watch_screen.dart';
import 'package:phimhay_app/main.dart'; // appNavigatorKey

/// Persistent mini-player overlay — floating card góc phải dưới
/// Luôn nằm ở Layer 2 của Root Stack, trên cùng tất cả nội dung
/// User có thể browse Home/Search trong khi video chạy
class MiniPlayerOverlay extends StatefulWidget {
  const MiniPlayerOverlay({super.key});

  @override
  State<MiniPlayerOverlay> createState() => _MiniPlayerOverlayState();
}

class _MiniPlayerOverlayState extends State<MiniPlayerOverlay> with WidgetsBindingObserver {
  final MovieService _movieService = MovieService();
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PlayerHolder.startPolling(() {
      if (mounted) setState(() {});
    });
    PlayerHolder.onStateChange(() {
      if (mounted) setState(() {});
    });
    _saveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _saveMiniPlayerProgress();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ★ FIX: Lưu progress khi kill app hoặc pause
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _saveMiniPlayerProgress();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PlayerHolder.stopPolling();
    PlayerHolder.onStateChange(null);
    _saveTimer?.cancel();
    super.dispose();
  }

  void _saveMiniPlayerProgress() {
    if (!PlayerHolder.isActive || PlayerHolder.movieId <= 0 || PlayerHolder.player == null) return;
    try {
      PlayerHolder.currentPosition = PlayerHolder.player!.state.position.inSeconds;
    } catch (_) {}
    _movieService.saveWatchProgress(
      movieId: PlayerHolder.movieId,
      episodeId: PlayerHolder.episodeId is int ? PlayerHolder.episodeId : null,
      serverIdx: PlayerHolder.serverIdx,
      position: PlayerHolder.currentPosition,
      duration: PlayerHolder.currentDuration,
      sourceType: 'hls',
      sourceUrl: PlayerHolder.currentUrl,
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Tap card → fullscreen WatchScreen
  void _goToFullscreen() {
    debugPrint('[MiniOverlay] _goToFullscreen called');
    debugPrint('[MiniOverlay] isActive=${PlayerHolder.isActive}, player=${PlayerHolder.player != null}, url=${PlayerHolder.currentUrl.isNotEmpty}');
    debugPrint('[MiniOverlay] isMiniPlayerMode=${PlayerHolder.isMiniPlayerMode}, isInWatch=${PlayerHolder.isInWatchScreen}');
    
    if (!PlayerHolder.isActive) {
      debugPrint('[MiniOverlay] SKIP: isActive=false');
      return;
    }
    if (PlayerHolder.player == null && PlayerHolder.currentUrl.isEmpty) {
      debugPrint('[MiniOverlay] SKIP: player=null AND url=empty');
      return;
    }

    final movieId = PlayerHolder.movieId;
    final epId = PlayerHolder.episodeId;
    final sIdx = PlayerHolder.serverIdx;
    final slug = PlayerHolder.movieSlug;
    final title = PlayerHolder.movieTitle;
    final pos = PlayerHolder.currentPosition;

    PlayerHolder.isMiniPlayerMode = false;
    PlayerHolder.isInWatchScreen = true;

    debugPrint('[MiniOverlay] Pushing WatchScreen: movieId=$movieId, epId=$epId, pos=$pos');
    // ★ FIX: Dùng appNavigatorKey thay vì context — context không phải descendant của Navigator
    appNavigatorKey.currentState!.push(
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

  /// Close mini-player entirely
  void _closeMiniPlayer() {
    PlayerHolder.player?.dispose();
    PlayerHolder.clear();
    // ★ FIX: Force rebuild ngay → overlay ẩn
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Không hiện nếu: chưa active, không ở mini mode, hoặc player đang trong WatchScreen
    if (!PlayerHolder.isActive || !PlayerHolder.isMiniPlayerMode) {
      return const SizedBox.shrink();
    }
    if (PlayerHolder.isInWatchScreen) return const SizedBox.shrink();

    // ★ FIX: Resume playback khi mini-player hiện
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (PlayerHolder.player != null && !PlayerHolder.isPlaying) {
        PlayerHolder.player!.play();
        PlayerHolder.isPlaying = true;
      }
      // Resume embed player
      if (PlayerHolder.player == null && PlayerHolder.currentUrl.isNotEmpty) {
        // Embed mode — player sẽ được tạo khi push WatchScreen
      }
    });

    final videoCtrl = PlayerHolder.videoController;
    final pos = Duration(seconds: PlayerHolder.currentPosition);
    final dur = Duration(seconds: PlayerHolder.currentDuration);
    final progress = PlayerHolder.currentDuration > 0
        ? PlayerHolder.currentPosition / PlayerHolder.currentDuration
        : 0.0;

    return Positioned(
      right: 12,
      bottom: 82, // Nâng lên cách mép trên BottomNav ~22px
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: _goToFullscreen,
          onVerticalDragEnd: (details) {
            final dy = details.velocity.pixelsPerSecond.dy;
            if (dy > 500) {
              // Vuốt xuống → dismiss
              _closeMiniPlayer();
            } else if (dy < -500) {
              // Vuốt lên → fullscreen
              _goToFullscreen();
            }
          },
          child: Container(
            width: 200,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1C21),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.6),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ★ Video thumbnail/live — 16:9 + close button overlay
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  child: SizedBox(
                    width: 200,
                    height: 112, // 200 * 9/16 = 112
                    child: Stack(
                      children: [
                        videoCtrl != null
                            ? Video(
                                controller: videoCtrl,
                                key: const ValueKey('mini_overlay_card'),
                                controls: NoVideoControls,
                              )
                            : Container(
                                color: Colors.black,
                                child: const Icon(Icons.movie, color: Colors.white24, size: 32),
                              ),
                        // ★ Close button — top-left corner
                        Positioned(
                          top: 4,
                          left: 4,
                          child: GestureDetector(
                            onTap: _closeMiniPlayer,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close_rounded, color: Colors.white70, size: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // ★ Controls row: rewind, play/pause, forward
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      GestureDetector(
                        onTap: () {
                          final target = max(0, PlayerHolder.currentPosition - 10);
                          PlayerHolder.player?.seek(Duration(seconds: target));
                        },
                        child: const Icon(Icons.replay_10_rounded, color: Colors.white70, size: 22),
                      ),
                      GestureDetector(
                        onTap: () {
                          if (PlayerHolder.isPlaying) {
                            PlayerHolder.player?.pause();
                          } else {
                            PlayerHolder.player?.play();
                          }
                        },
                        child: Icon(
                          PlayerHolder.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          final target = PlayerHolder.currentPosition + 10;
                          PlayerHolder.player?.seek(Duration(seconds: target));
                        },
                        child: const Icon(Icons.forward_10_rounded, color: Colors.white70, size: 22),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
