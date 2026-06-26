import 'dart:async';
import 'package:dio/dio.dart';

/// Represents a single segment in the m3u8 playlist
class M3u8Segment {
  final double duration;
  final String uri;
  final int index;
  final bool isAd;

  const M3u8Segment({
    required this.duration,
    required this.uri,
    required this.index,
    this.isAd = false,
  });

  @override
  String toString() => 'Seg[$index] ${duration}s ${isAd ? "AD" : "CONTENT"} $uri';
}

/// Represents a contiguous ad zone (one or more ad segments)
class AdZone {
  final double startTime;
  final double endTime;
  final double duration;
  final int startSegmentIndex;
  final int endSegmentIndex;

  const AdZone({
    required this.startTime,
    required this.endTime,
    required this.duration,
    required this.startSegmentIndex,
    required this.endSegmentIndex,
  });

  /// Check if a given position (in seconds) falls within this ad zone
  bool contains(double positionSec) =>
      positionSec >= startTime - 0.5 && positionSec < endTime + 0.5;

  /// How many seconds until the ad zone ends from a given position
  double remainingFrom(double positionSec) {
    if (positionSec < startTime) return duration;
    if (positionSec >= endTime) return 0;
    return endTime - positionSec;
  }

  @override
  String toString() =>
      'AdZone ${startTime.toStringAsFixed(1)}s-${endTime.toStringAsFixed(1)}s (${duration.toStringAsFixed(1)}s)';
}

/// Parse result containing all segments and detected ad zones
class M3u8ParseResult {
  final List<M3u8Segment> segments;
  final List<AdZone> adZones;
  final double totalDuration;
  final bool hasAds;

  const M3u8ParseResult({
    required this.segments,
    required this.adZones,
    required this.totalDuration,
    required this.hasAds,
  });

  /// Get the adjusted position: given a raw position, skip past any ad zones
  /// Returns the nearest content position after any ad at that point
  double adjustedPosition(double rawPosition) {
    for (final ad in adZones) {
      if (rawPosition >= ad.startTime && rawPosition < ad.endTime) {
        // Currently in ad zone → jump to end
        return ad.endTime;
      }
    }
    return rawPosition;
  }

  /// Find which ad zone (if any) contains the given position
  AdZone? adZoneAt(double positionSec) {
    for (final ad in adZones) {
      if (ad.contains(positionSec)) return ad;
    }
    return null;
  }

  /// Get next ad zone after a given position
  AdZone? nextAdAfter(double positionSec) {
    for (final ad in adZones) {
      if (ad.startTime > positionSec) return ad;
    }
    return null;
  }
}

/// Parses m3u8 playlists to detect ad segments and calculate exact durations.
///
/// Detection strategies (in priority order):
/// 1. EXT-X-DISCONTINUITY tags — marks boundary between content and ads
/// 2. URL pattern matching — ad domains / keywords in segment URLs
/// 3. EXT-X-DATERANGE with CLASS="AD" — server-declared ad regions
class M3u8AdParser {
  final Dio _dio;

  M3u8AdParser({Dio? dio}) : _dio = dio ?? Dio();

  /// Ad URL patterns — segment URLs matching these are treated as ads
  static const List<String> _adUrlPatterns = [
    'doubleclick',
    'googlesyndication',
    'googleadservices',
    'adserver',
    '/ads/',
    '/ad/',
    'advert',
    'tracking',
    'pixel',
    'beacon',
    'analytics',
    'sponsor',
    '.mp4', // pre-roll/mid-roll often use mp4 while content uses ts
  ];

  /// Fetch and parse an m3u8 playlist (handles multi-level playlists)
  Future<M3u8ParseResult> parse(String m3u8Url) async {
    // Step 1: Fetch the playlist
    final content = await _fetchPlaylist(m3u8Url);
    if (content == null) {
      return const M3u8ParseResult(
        segments: [],
        adZones: [],
        totalDuration: 0,
        hasAds: false,
      );
    }

    // Step 2: Check if this is a master playlist (contains variant streams)
    if (_isMasterPlaylist(content)) {
      // Pick the best quality variant and parse it
      final variantUrl = _selectBestVariant(content, m3u8Url);
      if (variantUrl != null) {
        final variantContent = await _fetchPlaylist(variantUrl);
        if (variantContent != null) {
          return _parseMediaPlaylist(variantContent);
        }
      }
      return const M3u8ParseResult(
        segments: [],
        adZones: [],
        totalDuration: 0,
        hasAds: false,
      );
    }

    // Step 3: Parse media playlist directly
    return _parseMediaPlaylist(content);
  }

  /// Fetch playlist content from URL
  Future<String?> _fetchPlaylist(String url) async {
    try {
      final response = await _dio.get(
        url,
        options: Options(
          headers: {
            'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
          },
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      return response.data?.toString();
    } catch (e) {
      return null;
    }
  }

  /// Check if content is a master playlist (contains #EXT-X-STREAM-INF)
  bool _isMasterPlaylist(String content) {
    return content.contains('#EXT-X-STREAM-INF');
  }

  /// Select the best quality variant from master playlist
  String? _selectBestVariant(String content, String masterUrl) {
    final lines = content.split('\n');
    String? bestUrl;
    int bestBandwidth = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        final bandwidth = _parseBandwidth(line);
        if (bandwidth > bestBandwidth && i + 1 < lines.length) {
          bestBandwidth = bandwidth;
          final variantLine = lines[i + 1].trim();
          if (variantLine.isNotEmpty && !variantLine.startsWith('#')) {
            bestUrl = _resolveUrl(variantLine, masterUrl);
          }
        }
      }
    }
    return bestUrl;
  }

  /// Parse bandwidth from EXT-X-STREAM-INF line
  int _parseBandwidth(String line) {
    final match = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
    return match != null ? int.parse(match.group(1)!) : 0;
  }

  /// Resolve relative URL against base URL
  String _resolveUrl(String uri, String baseUrl) {
    if (uri.startsWith('http://') || uri.startsWith('https://')) {
      return uri;
    }
    final baseUri = Uri.parse(baseUrl);
    return baseUri.resolve(uri).toString();
  }

  /// Parse a media playlist and detect ad zones
  M3u8ParseResult _parseMediaPlaylist(String content) {
    final lines = content.split('\n');
    final List<M3u8Segment> segments = [];
    final List<AdZone> adZones = [];

    double currentTime = 0;
    int segmentIndex = 0;
    bool nextSegmentIsAd = false;
    bool insideAdZone = false;
    int adStartIndex = 0;
    double adStartTime = 0;

    // Track discontinuity state
    bool lastDiscontinuityWasAd = false;
    bool hasDiscontinuityMarkers = false;

    double? pendingDuration;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      // ── EXT-X-DISCONTINUITY: marks content boundary ──
      if (line == '#EXT-X-DISCONTINUITY') {
        hasDiscontinuityMarkers = true;

        if (insideAdZone) {
          // End of ad zone
          adZones.add(AdZone(
            startTime: adStartTime,
            endTime: currentTime,
            duration: currentTime - adStartTime,
            startSegmentIndex: adStartIndex,
            endSegmentIndex: segmentIndex - 1,
          ));
          insideAdZone = false;
        }
        // Next segment could be ad — we determine by URL pattern
        nextSegmentIsAd = false;
        continue;
      }

      // ── EXT-X-DATERANGE with CLASS="AD" ──
      if (line.startsWith('#EXT-X-DATERANGE:')) {
        if (line.contains('CLASS="AD"') || line.contains("CLASS='AD'")) {
          final durationMatch =
              RegExp(r'DURATION=([\d.]+)').firstMatch(line);
          if (durationMatch != null) {
            final dur = double.parse(durationMatch.group(1)!);
            if (!insideAdZone) {
              insideAdZone = true;
              adStartIndex = segmentIndex;
              adStartTime = currentTime;
            }
            // The ad duration from DATERANGE — segments following will be
            // counted toward this
          }
        }
        continue;
      }

      // ── EXTINF: segment duration ──
      if (line.startsWith('#EXTINF:')) {
        final match = RegExp(r'#EXTINF:([\d.]+)').firstMatch(line);
        if (match != null) {
          pendingDuration = double.parse(match.group(1)!);
        }
        continue;
      }

      // ── Skip other # tags ──
      if (line.startsWith('#')) continue;

      // ── This line is a segment URI ──
      if (pendingDuration != null) {
        final duration = pendingDuration!;
        pendingDuration = null;

        // Determine if this segment is an ad
        final isAdByUrl = _isAdUrl(line);
        final isAd = isAdByUrl || nextSegmentIsAd || insideAdZone;

        if (isAd && !insideAdZone) {
          // Start of new ad zone
          insideAdZone = true;
          adStartIndex = segmentIndex;
          adStartTime = currentTime;
        } else if (!isAd && insideAdZone) {
          // Content resumed → close ad zone
          adZones.add(AdZone(
            startTime: adStartTime,
            endTime: currentTime,
            duration: currentTime - adStartTime,
            startSegmentIndex: adStartIndex,
            endSegmentIndex: segmentIndex - 1,
          ));
          insideAdZone = false;
        }

        segments.add(M3u8Segment(
          duration: duration,
          uri: line,
          index: segmentIndex,
          isAd: isAd,
        ));

        currentTime += duration;
        segmentIndex++;
      }
    }

    // Close any open ad zone at end of playlist
    if (insideAdZone) {
      adZones.add(AdZone(
        startTime: adStartTime,
        endTime: currentTime,
        duration: currentTime - adStartTime,
        startSegmentIndex: adStartIndex,
        endSegmentIndex: segmentIndex - 1,
      ));
    }

    return M3u8ParseResult(
      segments: segments,
      adZones: adZones,
      totalDuration: currentTime,
      hasAds: adZones.isNotEmpty,
    );
  }

  /// Check if a segment URL matches known ad patterns
  bool _isAdUrl(String url) {
    final lower = url.toLowerCase();
    return _adUrlPatterns.any((pattern) => lower.contains(pattern));
  }
}
