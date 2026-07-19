import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Global player state — mini-player lives at App level
class PlayerProvider extends ChangeNotifier {
  Player? player;
  VideoController? videoController;

  bool isMiniPlayerMode = false;
  bool isPlaying = false;
  int currentPosition = 0;
  int currentDuration = 0;

  // Movie/episode info
  int movieId = 0;
  String movieTitle = '';
  String movieSlug = '';
  dynamic episodeId;
  int serverIdx = 0;
  String epName = '';
  String currentUrl = '';
  bool hasActivePlayer = false;

  StreamSubscription? _subPosition;
  StreamSubscription? _subPlaying;
  StreamSubscription? _subDuration;

  void initPlayer(String url, Map<String, String> headers, {
    required int movieId,
    required String movieTitle,
    required String movieSlug,
    required dynamic episodeId,
    required int serverIdx,
    required String epName,
  }) {
    // Store info
    this.movieId = movieId;
    this.movieTitle = movieTitle;
    this.movieSlug = movieSlug;
    this.episodeId = episodeId;
    this.serverIdx = serverIdx;
    this.epName = epName;
    currentUrl = url;
    hasActivePlayer = true;

    // Dispose old player
    _disposePlayer();

    // Create new player
    player = Player();
    videoController = VideoController(player!);

    // Listen to streams
    _subPosition = player!.stream.position.listen((pos) {
      currentPosition = pos.inSeconds;
    });
    _subPlaying = player!.stream.playing.listen((playing) {
      isPlaying = playing;
    });
    _subDuration = player!.stream.duration.listen((dur) {
      currentDuration = dur.inSeconds;
    });

    // Open media
    player!.open(Media(url, httpHeaders: headers));

    notifyListeners();
  }

  void enterMiniPlayer() {
    isMiniPlayerMode = true;
    notifyListeners();
  }

  void exitMiniPlayer() {
    isMiniPlayerMode = false;
    notifyListeners();
  }

  void closeMiniPlayer() {
    _disposePlayer();
    hasActivePlayer = false;
    isMiniPlayerMode = false;
    notifyListeners();
  }

  void togglePlayPause() {
    if (isPlaying) {
      player?.pause();
    } else {
      player?.play();
    }
    notifyListeners();
  }

  void seek(Duration position) {
    player?.seek(position);
  }

  void updateEpisodeInfo({
    required dynamic episodeId,
    required String epName,
    required int serverIdx,
    required String url,
  }) {
    this.episodeId = episodeId;
    this.epName = epName;
    this.serverIdx = serverIdx;
    currentUrl = url;
    notifyListeners();
  }

  void _disposePlayer() {
    _subPosition?.cancel();
    _subPlaying?.cancel();
    _subDuration?.cancel();
    _subPosition = null;
    _subPlaying = null;
    _subDuration = null;
    player?.dispose();
    player = null;
    videoController = null;
  }

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }
}
