import 'package:dio/dio.dart';
import 'package:phimhay_app/config/app_config.dart';

class TmdbMovie {
  final int id;
  final String title;
  final String originalTitle;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final double voteAverage;
  final int voteCount;
  final String releaseDate;
  final List<int> genreIds;

  TmdbMovie({
    required this.id,
    required this.title,
    required this.originalTitle,
    required this.overview,
    this.posterPath,
    this.backdropPath,
    required this.voteAverage,
    required this.voteCount,
    required this.releaseDate,
    required this.genreIds,
  });

  String get posterUrl => posterPath != null && posterPath!.isNotEmpty
      ? '${AppConfig.tmdbImageBase}$posterPath'
      : '';
  String get backdropUrl => backdropPath != null && backdropPath!.isNotEmpty
      ? '${AppConfig.tmdbImageBase}$backdropPath'
      : '';

  factory TmdbMovie.fromJson(Map<String, dynamic> json) {
    return TmdbMovie(
      id: json['id'] ?? 0,
      title: json['title'] ?? '',
      originalTitle: json['original_title'] ?? '',
      overview: json['overview'] ?? '',
      posterPath: json['poster_path'],
      backdropPath: json['backdrop_path'],
      voteAverage: double.tryParse('${json['vote_average'] ?? 0}') ?? 0,
      voteCount: json['vote_count'] ?? 0,
      releaseDate: json['release_date'] ?? '',
      genreIds: json['genre_ids'] is String
          ? (json['genre_ids'] as String).split(',').map((e) => int.tryParse(e) ?? 0).toList()
          : List<int>.from(json['genre_ids'] ?? []),
    );
  }
}

class TmdbService {
  final Dio _dio = Dio();

  /// Fetch trending từ server API (cached trong MySQL)
  Future<List<TmdbMovie>> fetchTrending({String timeWindow = 'day', int limit = 10, String mediaType = 'movie'}) async {
    try {
      final response = await _dio.get(
        '${AppConfig.apiUrl}/tmdb_trending.php',
        queryParameters: {'window': timeWindow, 'limit': limit, 'media_type': mediaType},
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );

      final data = response.data;
      if (data is Map<String, dynamic> && data['success'] == true) {
        final results = data['results'] as List? ?? [];
        return results
            .map((e) => TmdbMovie.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      print('[TmdbService] Error: $e');
      return [];
    }
  }

  /// Fetch trending daily
  Future<List<TmdbMovie>> fetchTrendingDaily({int limit = 10}) {
    return fetchTrending(timeWindow: 'day', limit: limit);
  }

  /// Fetch trending weekly
  Future<List<TmdbMovie>> fetchTrendingWeekly({int limit = 10}) {
    return fetchTrending(timeWindow: 'week', limit: limit);
  }
}
