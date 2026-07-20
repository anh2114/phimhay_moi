import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/services/player_holder.dart';
import 'package:phimhay_app/screens/watch/watch_screen.dart';

/// Persistent mini-player overlay — floating card góc phải dưới
/// Luôn nằm ở Layer 2 của Root Stack, trên cùng tất cả nội dung
/// User có thể browse Home/Search trong khi video chạy
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
    // ★ Listen for immediate state changes (not polling)
    PlayerHolder.onStateChange(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    PlayerHolder.stopPolling();
    PlayerHolder.onStateChange(null);
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Tap card → fullscreen WatchScreen (reuse player từ PlayerHolder)
  void _goToFullscreen() {
    if (!PlayerHolder.isActive || PlayerHolder.player == null) return;

    final movieId = PlayerHolder.movieId;
    final epId = PlayerHolder.episodeId;
    final sIdx = PlayerHolder.serverIdx;
    final slug = PlayerHolder.movieSlug;
    final title = PlayerHolder.movieTitle;
    final pos = PlayerHolder.currentPosition;

    // ★ Đánh dấu TRƯỚC: overlay KHÔNG render Video
    PlayerHolder.isMiniPlayerMode = false;
    PlayerHolder.isInWatchScreen = true;
    // ★ Force rebuild ngay lập tức — xóa Video widget TRƯỚC khi push WatchScreen
    PlayerHolder.notifyStateChange();

    // ★ Force rebuild ngay → xóa Video widget
    PlayerHolder.notifyStateChange();

    // ★ FIX: Đợi 2 frames — frame 1: MiniPlayerOverlay rebuild (xóa Video)
    // frame 2: push WatchScreen (chỉ có 1 Video widget)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
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
      });
    });
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
    // Không hiện nếu: chưa active, không ở mini mode, không có player, hoặc player đang trong WatchScreen
    if (!PlayerHolder.isActive || !PlayerHolder.isMiniPlayerMode || PlayerHolder.player == null) {
      return const SizedBox.shrink();
    }
    if (PlayerHolder.isInWatchScreen) return const SizedBox.shrink();

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
                // ★ Video thumbnail/live — 16:9
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  child: SizedBox(
                    width: 200,
                    height: 112, // 200 * 9/16 = 112
                    child: videoCtrl != null
                        ? Video(
                            controller: videoCtrl,
                            key: const ValueKey('mini_overlay_card'),
                            controls: NoVideoControls,
                          )
                        : Container(
                            color: Colors.black,
                            child: const Icon(Icons.movie, color: Colors.white24, size: 32),
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
                // ★ Close button
                GestureDetector(
                  onTap: _closeMiniPlayer,
                  child: const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Icon(Icons.close_rounded, color: Colors.white38, size: 16),
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
