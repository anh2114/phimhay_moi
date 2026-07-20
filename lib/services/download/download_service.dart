import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Trạng thái download
enum DownloadStatus { queued, downloading, merging, completed, failed, cancelled }

/// Thông tin 1 file đang/đã download
class DownloadItem {
  final int movieId;
  final dynamic episodeId;
  final String movieName;
  final String movieSlug;
  final String movieThumb;
  final String epName;
  final String serverName;
  final String m3u8Url;
  final String filePath;       // đường dẫn file MP4 đã merge (hoặc folder segments)
  int fileSize;          // bytes (ước tính hoặc thực tế)
  DownloadStatus status;
  double progress;             // 0.0 → 1.0
  DateTime downloadedAt;       // thời gian download xong
  DateTime expiresAt;          // auto-delete sau 7 ngày
  bool isSeries;               // phim bộ?
  String? seriesName;          // tên phim bộ (để group các tập)

  DownloadItem({
    required this.movieId,
    required this.episodeId,
    required this.movieName,
    required this.movieSlug,
    required this.movieThumb,
    required this.epName,
    required this.serverName,
    required this.m3u8Url,
    required this.filePath,
    this.fileSize = 0,
    this.status = DownloadStatus.queued,
    this.progress = 0.0,
    DateTime? downloadedAt,
    DateTime? expiresAt,
    this.isSeries = false,
    this.seriesName,
  })  : downloadedAt = downloadedAt ?? DateTime.now(),
        expiresAt = expiresAt ?? DateTime.now().add(const Duration(days: 7));

  Map<String, dynamic> toJson() => {
        'movieId': movieId,
        'episodeId': episodeId,
        'movieName': movieName,
        'movieSlug': movieSlug,
        'movieThumb': movieThumb,
        'epName': epName,
        'serverName': serverName,
        'm3u8Url': m3u8Url,
        'filePath': filePath,
        'fileSize': fileSize,
        'status': status.index,
        'progress': progress,
        'downloadedAt': downloadedAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'isSeries': isSeries,
        'seriesName': seriesName,
      };

  factory DownloadItem.fromJson(Map<String, dynamic> json) => DownloadItem(
        movieId: json['movieId'] ?? 0,
        episodeId: json['episodeId'],
        movieName: json['movieName'] ?? '',
        movieSlug: json['movieSlug'] ?? '',
        movieThumb: json['movieThumb'] ?? '',
        epName: json['epName'] ?? '',
        serverName: json['serverName'] ?? '',
        m3u8Url: json['m3u8Url'] ?? '',
        filePath: json['filePath'] ?? '',
        fileSize: json['fileSize'] ?? 0,
        status: DownloadStatus.values[json['status'] ?? 0],
        progress: (json['progress'] ?? 0).toDouble(),
        downloadedAt: json['downloadedAt'] != null
            ? DateTime.tryParse(json['downloadedAt'])
            : null,
        expiresAt: json['expiresAt'] != null
            ? DateTime.tryParse(json['expiresAt'])
            : null,
        isSeries: json['isSeries'] ?? false,
        seriesName: json['seriesName'],
      );
}

/// Singleton service quản lý download
class DownloadService {
  static final DownloadService _instance = DownloadService._();
  factory DownloadService() => _instance;
  DownloadService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
  ));

  final List<DownloadItem> _queue = [];
  final Map<String, CancelToken> _cancelTokens = {};
  final StreamController<DownloadItem> _progressController =
      StreamController<DownloadItem>.broadcast();

  Stream<DownloadItem> get progressStream => _progressController.stream;
  List<DownloadItem> get queue => List.unmodifiable(_queue);
  bool _isProcessing = false;

  // ── Storage path ──

  Future<String> get _downloadDir async {
    final dir = await getApplicationDocumentsDirectory();
    final dlDir = Directory('${dir.path}/downloads');
    if (!await dlDir.exists()) await dlDir.create(recursive: true);
    return dlDir.path;
  }

  // ── Persistence ──

  Future<void> _saveQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _queue.map((e) => jsonEncode(e.toJson())).toList();
    await prefs.setStringList('download_queue', list);
  }

  Future<void> loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('download_queue') ?? [];
    _queue.clear();
    for (final s in list) {
      try {
        final item = DownloadItem.fromJson(jsonDecode(s));
        // Nếu download bị fail khi app tắt → reset về queued (chỉ khi app restart)
        if (item.status == DownloadStatus.downloading ||
            item.status == DownloadStatus.merging) {
          item.status = DownloadStatus.queued;
          item.progress = 0;
        }
        _queue.add(item);
      } catch (_) {}
    }
    // Xóa expired
    await _removeExpired();
    // Tự động process queue nếu có item queued
    _processQueue();
  }

  Future<void> _removeExpired() async {
    final now = DateTime.now();
    final toRemove = <DownloadItem>[];
    for (final item in _queue) {
      if (item.status == DownloadStatus.completed && item.expiresAt.isBefore(now)) {
        toRemove.add(item);
      }
    }
    for (final item in toRemove) {
      await deleteItem(item);
    }
  }

  // ── Public API ──

  /// Thêm download mới
  Future<void> addDownload({
    required int movieId,
    required dynamic episodeId,
    required String movieName,
    required String movieSlug,
    required String movieThumb,
    required String epName,
    required String serverName,
    required String m3u8Url,
    bool isSeries = false,
    String? seriesName,
  }) async {
    // Check trùng lặp
    final exists = _queue.any((item) =>
        item.movieId == movieId &&
        item.episodeId == episodeId &&
        item.status != DownloadStatus.failed &&
        item.status != DownloadStatus.cancelled);
    if (exists) return;

    final dir = await _downloadDir;
    final safeName = '${movieId}_${episodeId}_${DateTime.now().millisecondsSinceEpoch}.ts';

    final item = DownloadItem(
      movieId: movieId,
      episodeId: episodeId,
      movieName: movieName,
      movieSlug: movieSlug,
      movieThumb: movieThumb,
      epName: epName,
      serverName: serverName,
      m3u8Url: m3u8Url,
      filePath: '$dir/$safeName',
      isSeries: isSeries,
      seriesName: seriesName,
    );

    _queue.add(item);
    await _saveQueue();
    _progressController.add(item);
    _processQueue();
  }

  /// Hủy download
  Future<void> cancelDownload(DownloadItem item) async {
    final key = '${item.movieId}_${item.episodeId}';
    _cancelTokens[key]?.cancel();
    _cancelTokens.remove(key);
    item.status = DownloadStatus.cancelled;
    await _saveQueue();
    _progressController.add(item);
  }

  /// Xóa item đã download
  Future<void> deleteItem(DownloadItem item) async {
    // Hủy nếu đang download
    await cancelDownload(item);

    // Xóa file
    try {
      final file = File(item.filePath);
      if (await file.exists()) await file.delete();
      // Xóa folder .segments nếu có
      final segDir = Directory('${item.filePath}.segments');
      if (await segDir.exists()) await segDir.delete(recursive: true);
    } catch (_) {}

    _queue.remove(item);
    await _saveQueue();
    _progressController.add(item);
  }

  /// Lấy danh sách đã download xong
  List<DownloadItem> get completedItems =>
      _queue.where((i) => i.status == DownloadStatus.completed).toList();

  /// Lấy danh sách phim đã download (grouped by movie)
  Map<int, List<DownloadItem>> get completedGrouped {
    final map = <int, List<DownloadItem>>{};
    for (final item in completedItems) {
      map.putIfAbsent(item.movieId, () => []).add(item);
    }
    return map;
  }

  /// Check đã download tập này chưa
  bool isDownloaded(int movieId, dynamic episodeId) {
    return _queue.any((item) =>
        item.movieId == movieId &&
        item.episodeId == episodeId &&
        item.status == DownloadStatus.completed);
  }

  /// Check đang download tập này
  bool isDownloading(int movieId, dynamic episodeId) {
    return _queue.any((item) =>
        item.movieId == movieId &&
        item.episodeId == episodeId &&
        (item.status == DownloadStatus.downloading ||
         item.status == DownloadStatus.queued ||
         item.status == DownloadStatus.merging));
  }

  /// Get item by movieId + episodeId
  DownloadItem? getItem(int movieId, dynamic episodeId) {
    try {
      return _queue.firstWhere((item) =>
          item.movieId == movieId && item.episodeId == episodeId);
    } catch (_) {
      return null;
    }
  }

  /// Estimate file size từ m3u8 (parse #EXTINF durations)
  Future<int> estimateFileSize(String m3u8Url) async {
    try {
      final response = await _dio.get(m3u8Url);
      final content = response.data.toString();

      // Parse master playlist → tìm highest quality
      if (content.contains('#EXT-X-STREAM-INF')) {
        final lines = content.split('\n');
        String? bestUrl;
        int bestBandwidth = 0;
        for (int i = 0; i < lines.length; i++) {
          if (lines[i].contains('#EXT-X-STREAM-INF')) {
            final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i]);
            final bw = bwMatch != null ? int.parse(bwMatch.group(1)!) : 0;
            if (bw > bestBandwidth && i + 1 < lines.length) {
              bestBandwidth = bw;
              final nextLine = lines[i + 1].trim();
              if (nextLine.isNotEmpty && !nextLine.startsWith('#')) {
                final baseUrl = m3u8Url.substring(0, m3u8Url.lastIndexOf('/') + 1);
                bestUrl = nextLine.startsWith('http')
                    ? nextLine
                    : '$baseUrl$nextLine';
              }
            }
          }
        }
        if (bestUrl != null) return estimateFileSize(bestUrl);
      }

      // Parse media playlist → tính tổng duration × bandwidth
      double totalDuration = 0;
      final lines = content.split('\n');
      int? bandwidth;
      for (final line in lines) {
        if (line.startsWith('#EXT-X-STREAM-INF')) {
          final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
          if (bwMatch != null) bandwidth = int.parse(bwMatch.group(1)!);
        }
        if (line.startsWith('#EXTINF:')) {
          final durMatch = RegExp(r'#EXTINF:([\d.]+)').firstMatch(line);
          if (durMatch != null) {
            totalDuration += double.parse(durMatch.group(1)!);
          }
        }
      }
      // Estimate: bandwidth (bits/s) × duration (s) / 8 = bytes
      if (bandwidth != null && totalDuration > 0) {
        return ((bandwidth * totalDuration) / 8).toInt();
      }

      // Fallback: đếm số segments × ước tính mỗi segment
      final segCount = lines.where((l) => l.trim().isNotEmpty && !l.startsWith('#')).length;
      return segCount * 500000; // ~500KB per segment estimate
    } catch (_) {
      return 0;
    }
  }

  // ── Core download logic ──

  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;

    while (true) {
      final next = _queue.cast<DownloadItem?>().firstWhere(
            (item) => item!.status == DownloadStatus.queued,
            orElse: () => null,
          );
      if (next == null) break;

      await _downloadItem(next);
    }

    _isProcessing = false;
  }

  Future<void> _downloadItem(DownloadItem item) async {
    final key = '${item.movieId}_${item.episodeId}';
    final cancelToken = CancelToken();
    _cancelTokens[key] = cancelToken;

    try {
      item.status = DownloadStatus.downloading;
      item.progress = 0;
      _progressController.add(item);

      // Bước 1: Fetch m3u8
      final m3u8Content = await _fetchM3u8(item.m3u8Url);
      if (m3u8Content == null) throw Exception('Không thể tải m3u8');

      // Bước 2: Resolve segments
      final segments = await _resolveSegments(m3u8Content, item.m3u8Url);
      if (segments.isEmpty) throw Exception('Không tìm thấy video segments');

      // Bước 3: Download tất cả segments
      final dir = await _downloadDir;
      final segDir = '$dir/${item.movieId}_${item.episodeId}';
      final segDirObj = Directory(segDir);
      if (!await segDirObj.exists()) await segDirObj.create(recursive: true);

      int downloaded = 0;

      for (int i = 0; i < segments.length; i++) {
        if (cancelToken.isCancelled) throw Exception('Cancelled');

        final segUrl = segments[i];
        final segFile = '$segDir/seg_${i.toString().padLeft(6, '0')}.ts';

        if (await File(segFile).exists()) {
          downloaded++;
          item.progress = downloaded / segments.length;
          _progressController.add(item);
          continue;
        }

        try {
          await _dio.download(
            segUrl,
            segFile,
            cancelToken: cancelToken,
            options: Options(headers: {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
            }),
          );
          downloaded++;
          item.progress = downloaded / segments.length;
          _progressController.add(item);
        } catch (e) {
          if (cancelToken.isCancelled) rethrow;
          // Skip failed segment, continue
          downloaded++;
          item.progress = downloaded / segments.length;
          _progressController.add(item);
        }
      }

      if (cancelToken.isCancelled) throw Exception('Cancelled');

      // Bước 4: Merge segments thành MP4
      item.status = DownloadStatus.merging;
      item.progress = 1.0;
      _progressController.add(item);

      await _mergeSegments(segDir, segments.length, item.filePath);

      // Cleanup segments
      try {
        await segDirObj.delete(recursive: true);
      } catch (_) {}

      // Bước 5: Hoàn thành
      final file = File(item.filePath);
      if (await file.exists()) {
        item.fileSize = await file.length();
      } else {
        throw Exception('File không tồn tại sau khi merge');
      }

      item.status = DownloadStatus.completed;
      item.progress = 1.0;
      item.downloadedAt = DateTime.now();
      item.expiresAt = DateTime.now().add(const Duration(days: 7));
      _progressController.add(item);
      await _saveQueue();
    } catch (e) {
      if (cancelToken.isCancelled || e.toString().contains('Cancelled')) {
        item.status = DownloadStatus.cancelled;
      } else {
        item.status = DownloadStatus.failed;
      }
      item.progress = 0;
      _progressController.add(item);
      await _saveQueue();
    } finally {
      _cancelTokens.remove(key);
    }
  }

  Future<String?> _fetchM3u8(String url) async {
    try {
      final response = await _dio.get(url,
          options: Options(headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
          }));
      return response.data?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _resolveSegments(String m3u8Content, String baseUrl) async {
    final segments = <String>[];
    final lines = m3u8Content.split('\n');

    // Check master playlist
    if (m3u8Content.contains('#EXT-X-STREAM-INF')) {
      String? bestUrl;
      int bestBandwidth = 0;
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].contains('#EXT-X-STREAM-INF')) {
          final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i]);
          final bw = bwMatch != null ? int.parse(bwMatch.group(1)!) : 0;
          if (bw > bestBandwidth && i + 1 < lines.length) {
            bestBandwidth = bw;
            final nextLine = lines[i + 1].trim();
            if (nextLine.isNotEmpty && !nextLine.startsWith('#')) {
              bestUrl = _resolveUrl(nextLine, baseUrl);
            }
          }
        }
      }
      if (bestUrl != null) {
        final sub = await _fetchM3u8(bestUrl);
        if (sub != null) return _resolveSegments(sub, bestUrl);
      }
      return segments;
    }

    // Media playlist
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (trimmed.endsWith('.ts') || trimmed.contains('.ts?')) {
        segments.add(_resolveUrl(trimmed, baseUrl));
      }
    }
    return segments;
  }

  String _resolveUrl(String path, String baseUrl) {
    if (path.startsWith('http')) return path;
    final base = baseUrl.substring(0, baseUrl.lastIndexOf('/') + 1);
    return '$base$path';
  }

  Future<void> _mergeSegments(
      String segDir, int segCount, String outputPath) async {
    // Đơn giản: nối tất cả .ts binary thành 1 file
    // mpv/media_kit vẫn play được file .ts renamed thành .mp4
    final outFile = File(outputPath);
    final sink = outFile.openWrite();

    for (int i = 0; i < segCount; i++) {
      final segFile = File('$segDir/seg_${i.toString().padLeft(6, '0')}.ts');
      if (await segFile.exists()) {
        final bytes = await segFile.readAsBytes();
        sink.add(bytes);
      }
    }

    await sink.flush();
    await sink.close();
  }

  void dispose() {
    _progressController.close();
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
  }
}
