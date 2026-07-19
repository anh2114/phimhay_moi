import 'dart:async';
import 'dart:ui';

/// Global player holder — static state for mini-player at App level
/// Player là entity toàn cục, KHÔNG thuộc về bất kỳ Screen nào
class PlayerHolder {
  static dynamic player;
  static dynamic videoController;
  static bool isActive = false;
  static bool isMiniPlayerMode = false;
  static bool isInWatchScreen = false;
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
  static VoidCallback? _onStateChange;

  static void startPolling(VoidCallback onUpdate) {
    _onUpdate = onUpdate;
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (player != null && isActive) {
        try {
          currentPosition = player!.state.position.inSeconds;
          isPlaying = player!.state.playing;
          currentDuration = player!.state.duration.inSeconds;
        } catch (_) {}
      }
      _onUpdate?.call();
    });
  }

  /// Register callback for immediate state changes (not polling)
  static void onStateChange(VoidCallback? callback) {
    _onStateChange = callback;
  }

  /// Trigger immediate rebuild of MiniPlayerOverlay
  static void notifyStateChange() {
    _onStateChange?.call();
  }

  static void stopPolling() {
    _updateTimer?.cancel();
    _updateTimer = null;
    _onUpdate = null;
  }

  /// Transfer player từ WatchScreen → PlayerHolder (khi entering mini-player)
  static void takeFromWatchScreen({
    required dynamic p,
    required dynamic vc,
    required bool playing,
    required int pos,
    required int dur,
    required int mId,
    required String title,
    required String slug,
    required dynamic epId,
    required int sIdx,
    required String ep,
    required String url,
  }) {
    player = p;
    videoController = vc;
    isPlaying = playing;
    currentPosition = pos;
    currentDuration = dur;
    movieId = mId;
    movieTitle = title;
    movieSlug = slug;
    episodeId = epId;
    serverIdx = sIdx;
    epName = ep;
    currentUrl = url;
    isActive = true;
    isMiniPlayerMode = true;
    isInWatchScreen = false;
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
