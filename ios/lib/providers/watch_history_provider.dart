import 'package:flutter/foundation.dart';
import '../models/movie.dart';
import '../services/api_client.dart';

class WatchHistoryMovie {
  final int movieId;
  final String slug;
  final String name;
  final String originName;
  final String thumbUrl;
  final String posterUrl;
  final String type;
  final int episodeTotal;
  final String epName;
  final String epSlug;
  final int serverIdx;
  final int position;
  final int duration;
  final int progress;
  final String watchedAt;

  WatchHistoryMovie({
    required this.movieId,
    required this.slug,
    required this.name,
    required this.originName,
    required this.thumbUrl,
    required this.posterUrl,
    required this.type,
    required this.episodeTotal,
    required this.epName,
    required this.epSlug,
    required this.serverIdx,
    required this.position,
    required this.duration,
    required this.progress,
    required this.watchedAt,
  });

  factory WatchHistoryMovie.fromJson(Map<String, dynamic> json) {
    return WatchHistoryMovie(
      movieId: json['movie_id'] ?? 0,
      slug: json['slug'] ?? '',
      name: json['name'] ?? '',
      originName: json['origin_name'] ?? '',
      thumbUrl: json['thumb_url'] ?? '',
      posterUrl: json['poster_url'] ?? '',
      type: json['type'] ?? '',
      episodeTotal: json['episode_total'] ?? 0,
      epName: json['ep_name'] ?? '',
      epSlug: json['ep_slug'] ?? '',
      serverIdx: json['server_idx'] ?? 0,
      position: json['position'] ?? 0,
      duration: json['duration'] ?? 0,
      progress: json['progress'] ?? 0,
      watchedAt: json['watched_at'] ?? '',
    );
  }

  Movie toMovie() {
    return Movie(
      id: movieId,
      slug: slug,
      name: name,
      originName: originName,
      thumbUrl: thumbUrl,
      posterUrl: posterUrl,
      type: type,
      episodeTotal: episodeTotal.toString(),
    );
  }

  String get episodeDisplay {
    final clean = epName.replaceAll(RegExp(r'tập\s*', caseSensitive: false), '').trim();
    return clean.isEmpty ? '1' : clean;
  }

  String get timeDisplay {
    final posMin = position ~/ 60;
    final durMin = duration ~/ 60;
    return '${posMin}m / ${durMin}m';
  }
}

class WatchHistoryProvider extends ChangeNotifier {
  Movie? _lastViewedMovie;
  List<WatchHistoryMovie> _continueWatching = [];
  bool _isLoadingContinue = false;
  String? _continueError;

  Movie? get lastViewedMovie => _lastViewedMovie;
  List<WatchHistoryMovie> get continueWatching => _continueWatching;
  bool get isLoadingContinue => _isLoadingContinue;
  String? get continueError => _continueError;

  void setLastViewed(Movie movie) {
    _lastViewedMovie = movie;
    notifyListeners();
  }

  Future<void> fetchContinueWatching() async {
    if (!ApiClient.isAuth) {
      _continueWatching = [];
      notifyListeners();
      return;
    }

    _isLoadingContinue = true;
    _continueError = null;
    notifyListeners();

    try {
      final res = await ApiClient.get('/continue_watching.php', params: {'limit': '10'});
      final data = res.data;
      if (data['success'] == true) {
        final list = (data['movies'] as List<dynamic>?) ?? [];
        _continueWatching = list
            .map((e) => WatchHistoryMovie.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } else {
        _continueWatching = [];
      }
    } catch (e) {
      _continueError = 'Không thể tải lịch sử';
      _continueWatching = [];
    }

    _isLoadingContinue = false;
    notifyListeners();
  }

  Future<void> removeFromHistory(int movieId) async {
    try {
      await ApiClient.dio.delete('/WatchProgress.php', queryParameters: {'movie_id': movieId});
      _continueWatching.removeWhere((e) => e.movieId == movieId);
      notifyListeners();
    } catch (_) {}
  }

  void clear() {
    _lastViewedMovie = null;
    _continueWatching = [];
    notifyListeners();
  }
}
