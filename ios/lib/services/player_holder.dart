/// Global player holder — simple static state for mini-player
/// Avoids Provider complexity, guarantees single player instance
class PlayerHolder {
  static dynamic player;        // Player instance (media_kit)
  static dynamic videoController; // VideoController
  static bool isActive = false;
  static bool isMiniPlayerMode = false;
  static int currentPosition = 0;
  static int currentDuration = 0;
  static bool isPlaying = false;

  // Movie/episode info
  static int movieId = 0;
  static String movieTitle = '';
  static String movieSlug = '';
  static dynamic episodeId;
  static int serverIdx = 0;
  static String epName = '';
  static String currentUrl = '';

  static void clear() {
    player = null;
    videoController = null;
    isActive = false;
    isMiniPlayerMode = false;
    currentPosition = 0;
    currentDuration = 0;
    isPlaying = false;
  }
}
