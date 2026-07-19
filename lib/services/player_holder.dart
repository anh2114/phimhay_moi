import 'dart:async';
import 'dart:ui';

/// Global player holder — static state for mini-player at App level
class PlayerHolder {
  static dynamic player;
  static dynamic videoController;
  static bool isActive = false;
  static bool isMiniPlayerMode = false;
  static bool isInWatchScreen = false; // Player đang trong WatchScreen
  static int currentPosition = 0;
  static int currentDuration = 0;
  static bool isPlaying = false;

  static int movieId = 0;
  static String movieTitle = '';
  static String movieSlug = '';
  static dynamic episodeId;
  static int serverIdx = 0;
  static String epName = '';
  static String currentUrl = '';

  static Timer? _updateTimer;
  static VoidCallback? _onUpdate;

  /// Start polling player state for overlay updates
  static void startPolling(VoidCallback onUpdate) {
    _onUpdate = onUpdate;
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      // Update position from player
      if (player != null && isActive) {
        try {
          final pos = player!.state.position;
          currentPosition = pos.inSeconds;
          isPlaying = player!.state.playing;
          final dur = player!.state.duration;
          currentDuration = dur.inSeconds;
        } catch (_) {}
      }
      _onUpdate?.call();
    });
  }

  static void stopPolling() {
    _updateTimer?.cancel();
    _updateTimer = null;
    _onUpdate = null;
  }

  static void clear() {
    player = null;
    videoController = null;
    isActive = false;
    isMiniPlayerMode = false;
    isInWatchScreen = false;
    currentPosition = 0;
    currentDuration = 0;
    isPlaying = false;
    stopPolling();
  }
}
