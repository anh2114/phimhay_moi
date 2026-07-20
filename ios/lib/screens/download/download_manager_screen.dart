import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:phimhay_app/config/app_config.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/screens/watch/watch_screen.dart';
import 'package:phimhay_app/services/download/download_service.dart';
import 'package:phimhay_app/services/image_cache_manager.dart';

class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({super.key});

  @override
  State<DownloadManagerScreen> createState() => _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  final DownloadService _downloadService = DownloadService();
  StreamSubscription<DownloadItem>? _progressSub;

  @override
  void initState() {
    super.initState();
    // Listen to progress updates to refresh UI
    _progressSub = _downloadService.progressStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatExpiry(DateTime expiresAt) {
    final diff = expiresAt.difference(DateTime.now());
    if (diff.isNegative) return 'Đã hết hạn';
    if (diff.inDays > 0) return 'Còn ${diff.inDays} ngày';
    if (diff.inHours > 0) return 'Còn ${diff.inHours} giờ';
    return 'Sắp hết hạn';
  }

  void _playDownloadedItem(DownloadItem item) async {
    final file = File(item.filePath);
    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File không tồn tại'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WatchScreen(
          movieId: item.movieId,
          episodeId: item.episodeId,
          serverIdx: 0,
          streamUrl: item.filePath, // Local file path
          movieSlug: item.movieSlug,
          movieTitle: item.movieName,
        ),
      ),
    );
  }

  void _deleteItem(DownloadItem item) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2026),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Xóa phim đã tải',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        content: Text(
          'Xóa "${item.movieName} - ${item.epName}"?\nHành động này không thể hoàn tác.',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _downloadService.deleteItem(item);
              setState(() {});
            },
            child: const Text('Xóa',
                style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  void _deleteAll() {
    final completed = _downloadService.completedItems;
    if (completed.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2026),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Xóa tất cả',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        content: Text(
          'Xóa tất cả ${completed.length} phim đã tải?\nHành động này không thể hoàn tác.',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              for (final item in completed) {
                _downloadService.deleteItem(item);
              }
              setState(() {});
            },
            child: const Text('Xóa tất cả',
                style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final completed = _downloadService.completedItems;
    final downloading = _downloadService.queue
        .where((i) =>
            i.status == DownloadStatus.downloading ||
            i.status == DownloadStatus.queued ||
            i.status == DownloadStatus.merging)
        .toList();

    // Group completed by movieId
    final grouped = <int, List<DownloadItem>>{};
    for (final item in completed) {
      grouped.putIfAbsent(item.movieId, () => []).add(item);
    }

    // Calculate total size
    int totalSize = 0;
    for (final item in completed) {
      totalSize += item.fileSize;
    }

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        foregroundColor: Colors.white,
        title: const Text('Quản lý tải xuống',
            style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          if (completed.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded, size: 22),
              onPressed: _deleteAll,
              tooltip: 'Xóa tất cả',
            ),
        ],
      ),
      body: grouped.isEmpty && downloading.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.download_done_rounded,
                      size: 64, color: AppTheme.textMuted.withValues(alpha: 0.5)),
                  const SizedBox(height: 16),
                  const Text(
                    'Chưa có phim nào được tải về',
                    style: TextStyle(color: AppTheme.textSub, fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Mở phim và nhấn nút tải để bắt đầu',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Storage info
                if (completed.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppTheme.bgCard,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.storage_rounded,
                            color: AppTheme.accent, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${completed.length} phim đã tải',
                                style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600),
                              ),
                              Text(
                                'Tổng dung lượng: ${_formatSize(totalSize)}',
                                style: const TextStyle(
                                    color: AppTheme.textMuted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                // Downloading section
                if (downloading.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Đang tải',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  ...downloading.map((item) => _buildDownloadingItem(item)),
                ],

                // Completed section
                if (grouped.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Đã tải về',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  ...grouped.entries.map((entry) {
                    final items = entry.value;
                    if (items.length == 1) {
                      return _buildCompletedItem(items.first);
                    }
                    return _buildSeriesGroup(entry.key, items);
                  }),
                ],
              ],
            ),
    );
  }

  Widget _buildDownloadingItem(DownloadItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: item.movieThumb.isNotEmpty
                      ? (item.movieThumb.startsWith('http')
                          ? item.movieThumb
                          : '${AppConfig.baseUrl}${item.movieThumb}')
                      : '',
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  cacheManager: AppImageCacheManager(),
                  errorWidget: (_, __, ___) => Container(
                    width: 48,
                    height: 48,
                    color: AppTheme.bgSurface,
                    child: const Icon(Icons.movie, color: AppTheme.textMuted),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.movieName,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      item.epName,
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                onPressed: () => _downloadService.cancelDownload(item),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: item.progress,
                    backgroundColor: AppTheme.bgSurface,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(AppTheme.accent),
                    minHeight: 4,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${(item.progress * 100).toStringAsFixed(0)}%',
                style:
                    const TextStyle(color: AppTheme.accent, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSeriesGroup(int movieId, List<DownloadItem> items) {
    final first = items.first;
    final isExpanded = ValueNotifier<bool>(false);

    return ValueListenableBuilder<bool>(
      valueListenable: isExpanded,
      builder: (_, expanded, __) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Series header
            GestureDetector(
              onTap: () => isExpanded.value = !expanded,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedNetworkImage(
                        imageUrl: first.movieThumb.isNotEmpty
                            ? (first.movieThumb.startsWith('http')
                                ? first.movieThumb
                                : '${AppConfig.baseUrl}${first.movieThumb}')
                            : '',
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        cacheManager: AppImageCacheManager(),
                        errorWidget: (_, __, ___) => Container(
                          width: 48,
                          height: 48,
                          color: AppTheme.bgSurface,
                          child: const Icon(Icons.movie,
                              color: AppTheme.textMuted),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            first.movieName,
                            style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${items.length} tập đã tải',
                            style: const TextStyle(
                                color: AppTheme.textMuted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(Icons.expand_more_rounded,
                          color: AppTheme.textMuted, size: 22),
                    ),
                  ],
                ),
              ),
            ),
            // Episodes list (expandable)
            if (expanded) ...[
              const Divider(color: Colors.white10, height: 1),
              ...items.map((item) => _buildEpisodeItem(item)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEpisodeItem(DownloadItem item) {
    final isExpired = item.expiresAt.isBefore(DateTime.now());
    return InkWell(
      onTap: isExpired ? null : () => _playDownloadedItem(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              isExpired ? Icons.timer_off_rounded : Icons.play_circle_outline_rounded,
              color: isExpired ? Colors.redAccent : AppTheme.accent,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.epName,
                    style: TextStyle(
                      color: isExpired ? Colors.redAccent : AppTheme.textPrimary,
                      fontSize: 14,
                    ),
                  ),
                  Row(
                    children: [
                      if (item.fileSize > 0)
                        Text(
                          _formatSize(item.fileSize),
                          style: const TextStyle(
                              color: AppTheme.textMuted, fontSize: 11),
                        ),
                      if (item.fileSize > 0) const SizedBox(width: 8),
                      Text(
                        _formatExpiry(item.expiresAt),
                        style: TextStyle(
                          color: isExpired ? Colors.redAccent : AppTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: Colors.redAccent, size: 18),
              onPressed: () => _deleteItem(item),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompletedItem(DownloadItem item) {
    final isExpired = item.expiresAt.isBefore(DateTime.now());
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isExpired ? Colors.redAccent.withValues(alpha: 0.3) : AppTheme.border),
      ),
      child: InkWell(
        onTap: isExpired ? null : () => _playDownloadedItem(item),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  children: [
                    CachedNetworkImage(
                      imageUrl: item.movieThumb.isNotEmpty
                          ? (item.movieThumb.startsWith('http')
                              ? item.movieThumb
                              : '${AppConfig.baseUrl}${item.movieThumb}')
                          : '',
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      cacheManager: AppImageCacheManager(),
                      errorWidget: (_, __, ___) => Container(
                        width: 64,
                        height: 64,
                        color: AppTheme.bgSurface,
                        child: const Icon(Icons.movie, color: AppTheme.textMuted),
                      ),
                    ),
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                          isExpired ? Icons.timer_off_rounded : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.movieName,
                      style: TextStyle(
                        color: isExpired ? Colors.white54 : AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.epName,
                      style: TextStyle(
                        color: isExpired ? Colors.redAccent : AppTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (item.fileSize > 0) ...[
                          const Icon(Icons.storage_rounded,
                              size: 12, color: AppTheme.textMuted),
                          const SizedBox(width: 4),
                          Text(
                            _formatSize(item.fileSize),
                            style: const TextStyle(
                                color: AppTheme.textMuted, fontSize: 11),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Icon(
                          isExpired ? Icons.timer_off_rounded : Icons.access_time_rounded,
                          size: 12,
                          color: isExpired ? Colors.redAccent : AppTheme.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatExpiry(item.expiresAt),
                          style: TextStyle(
                            color: isExpired ? Colors.redAccent : AppTheme.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: Colors.redAccent, size: 20),
                onPressed: () => _deleteItem(item),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
