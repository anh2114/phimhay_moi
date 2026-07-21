import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Intro timestamp data from IntroDB
class IntroData {
  final int startSec;
  final int endSec;
  final int confidence;

  const IntroData({
    required this.startSec,
    required this.endSec,
    this.confidence = 0,
  });

  factory IntroData.fromJson(Map<String, dynamic> json) {
    return IntroData(
      startSec: (json['start_sec'] ?? 0).toInt(),
      endSec: (json['end_sec'] ?? 0).toInt(),
      confidence: (json['confidence'] ?? 0).toInt(),
    );
  }

  /// Duration in seconds
  int get duration => endSec - startSec;

  /// Check if a given position (seconds) is within intro range
  bool isInRange(int position) => position >= startSec && position <= endSec;

  /// Check if position is near intro start (5 seconds before)
  bool isNearStart(int position) => position >= startSec - 5 && position <= endSec;
}

/// Service to fetch intro timestamps from IntroDB API
class IntroService {
  static final IntroService _instance = IntroService._();
  factory IntroService() => _instance;
  IntroService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
  ));

  static const String _baseUrl = 'https://api.introdb.app';
  static const String _cachePrefix = 'intro_cache_';
  static const Duration _cacheTtl = Duration(days: 7);

  /// Fetch intro data for a specific episode
  /// Returns null if no data available
  Future<IntroData?> getIntro({
    required String imdbId,
    required int season,
    required int episode,
  }) async {
    if (imdbId.isEmpty || imdbId == 'tt0000000') return null;

    // Check cache first
    final cached = await _getCached(imdbId, season, episode);
    if (cached != null) return cached;

    // Fetch from API
    try {
      final response = await _dio.get(
        '$_baseUrl/segments',
        queryParameters: {
          'imdb_id': imdbId,
          'season': season,
          'episode': episode,
        },
      );

      if (response.statusCode == 200 && response.data is Map) {
        final data = response.data as Map<String, dynamic>;
        final introJson = data['intro'];

        if (introJson != null && introJson is Map<String, dynamic>) {
          final intro = IntroData.fromJson(introJson);

          // Only cache if confidence > 0 and valid duration
          if (intro.confidence > 0 && intro.duration > 10) {
            await _setCached(imdbId, season, episode, intro);
            return intro;
          }
        }
      }
    } catch (_) {
      // Silent fail — return null
    }

    return null;
  }

  /// Cache key
  String _cacheKey(String imdbId, int season, int episode) {
    return '$_cachePrefix${imdbId}_s${season}e$episode';
  }

  /// Get cached intro data
  Future<IntroData?> _getCached(String imdbId, int season, int episode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _cacheKey(imdbId, season, episode);
      final raw = prefs.getString(key);
      if (raw == null) return null;

      final data = jsonDecode(raw);
      final expiresAt = DateTime.parse(data['expires_at']);
      if (DateTime.now().isAfter(expiresAt)) {
        await prefs.remove(key);
        return null;
      }

      return IntroData.fromJson(data['intro']);
    } catch (_) {
      return null;
    }
  }

  /// Save intro data to cache
  Future<void> _setCached(
      String imdbId, int season, int episode, IntroData intro) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _cacheKey(imdbId, season, episode);
      final data = {
        'intro': {
          'start_sec': intro.startSec,
          'end_sec': intro.endSec,
          'confidence': intro.confidence,
        },
        'expires_at': DateTime.now().add(_cacheTtl).toIso8601String(),
      };
      await prefs.setString(key, jsonEncode(data));
    } catch (_) {}
  }

  /// Clear all intro cache
  Future<void> clearCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_cachePrefix));
      for (final key in keys) {
        await prefs.remove(key);
      }
    } catch (_) {}
  }
}
