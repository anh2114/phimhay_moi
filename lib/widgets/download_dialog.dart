import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/services/download/download_service.dart';

/// Dialog chọn tập để download — layout giống server selector trong fullscreen
void showDownloadDialog({
  required BuildContext context,
  required int movieId,
  required String movieName,
  required String movieSlug,
  required String movieThumb,
  required List<Map<String, dynamic>> servers,
  required List<Map<String, dynamic>> serverSources,
  bool isSeries = false,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _DownloadDialogBody(
      movieId: movieId,
      movieName: movieName,
      movieSlug: movieSlug,
      movieThumb: movieThumb,
      servers: servers,
      serverSources: serverSources,
      isSeries: isSeries,
    ),
  );
}

class _DownloadDialogBody extends StatefulWidget {
  final int movieId;
  final String movieName;
  final String movieSlug;
  final String movieThumb;
  final List<Map<String, dynamic>> servers;
  final List<Map<String, dynamic>> serverSources;
  final bool isSeries;

  const _DownloadDialogBody({
    required this.movieId,
    required this.movieName,
    required this.movieSlug,
    required this.movieThumb,
    required this.servers,
    required this.serverSources,
    required this.isSeries,
  });

  @override
  State<_DownloadDialogBody> createState() => _DownloadDialogBodyState();
}

class _DownloadDialogBodyState extends State<_DownloadDialogBody> {
  int _selectedSource = 0;
  int _selectedSourceServer = 0;
  int _episodePage = 1;
  static const int _episodesPerPage = 100;
  final DownloadService _downloadService = DownloadService();
  final Map<String, int> _sizes = {}; // cache estimated sizes
  final Map<String, double> _progressMap = {}; // movieId_epId → progress
  StreamSubscription<DownloadItem>? _progressSub;

  @override
  void initState() {
    super.initState();
    // Listen to progress updates
    _progressSub = _downloadService.progressStream.listen((item) {
      if (!mounted) return;
      final key = '${item.movieId}_${item.episodeId}';
      setState(() {
        if (item.status == DownloadStatus.completed ||
            item.status == DownloadStatus.failed ||
            item.status == DownloadStatus.cancelled) {
          _progressMap.remove(key);
        } else {
          _progressMap[key] = item.progress;
        }
      });
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  List<Map<String, dynamic>> get _sourceServers {
    if (widget.serverSources.isNotEmpty &&
        _selectedSource < widget.serverSources.length) {
      return (widget.serverSources[_selectedSource]['servers']
              as List<dynamic>)
          .cast<Map<String, dynamic>>();
    }
    return widget.servers;
  }

  Map<String, dynamic>? get _currentServer {
    final servers = _sourceServers;
    if (servers.isEmpty) return null;
    if (_selectedSourceServer < servers.length) {
      return servers[_selectedSourceServer];
    }
    return servers.first;
  }

  List<dynamic> get _currentEps {
    final server = _currentServer;
    if (server == null) return [];
    return (server['episodes'] as List<dynamic>?) ?? [];
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return 'Đang tính...';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<int> _getEpisodeSize(dynamic ep) async {
    final m3u8 = (ep['link_m3u8'] ?? '').toString().trim();
    if (m3u8.isEmpty) return 0;
    final key = '${widget.movieId}_${ep['id']}';
    if (_sizes.containsKey(key)) return _sizes[key]!;
    final size = await _downloadService.estimateFileSize(m3u8);
    if (mounted) setState(() => _sizes[key] = size);
    return size;
  }

  void _confirmDownload(dynamic ep) {
    final epName = (ep['ep_name'] ?? ep['name'] ?? '').toString();
    final m3u8 = (ep['link_m3u8'] ?? '').toString().trim();
    if (m3u8.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tập này không có link download'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final key = '${widget.movieId}_${ep['id']}';
    final size = _sizes[key];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2026),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Xác nhận tải về',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.movieName,
              style: const TextStyle(
                  color: AppTheme.accent,
                  fontSize: 15,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Tập: $epName',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            if (size != null && size > 0) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.storage_rounded,
                      size: 16, color: AppTheme.textMuted),
                  const SizedBox(width: 6),
                  Text(
                    'Dung lượng: ${_formatSize(size)}',
                    style: const TextStyle(
                        color: AppTheme.textSub, fontSize: 13),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: Colors.blue),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Phim sẽ tự xóa sau 7 ngày để giải phóng bộ nhớ',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _startDownload(ep);
            },
            child: const Text('Tải về',
                style: TextStyle(
                    color: AppTheme.accent, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  void _startDownload(dynamic ep) {
    final epName = (ep['ep_name'] ?? ep['name'] ?? '').toString();
    final m3u8 = (ep['link_m3u8'] ?? '').toString().trim();
    final serverName =
        (_currentServer?['server_name'] ?? '').toString();

    _downloadService.addDownload(
      movieId: widget.movieId,
      episodeId: ep['id'],
      movieName: widget.movieName,
      movieSlug: widget.movieSlug,
      movieThumb: widget.movieThumb,
      epName: epName,
      serverName: serverName,
      m3u8Url: m3u8,
      isSeries: widget.isSeries,
      seriesName: widget.isSeries ? widget.movieName : null,
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đang tải: $epName'),
        backgroundColor: const Color(0xFF2E7D32),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalEps = _currentEps.length;
    final totalPages = (totalEps / _episodesPerPage).ceil();
    final startIdx = (_episodePage - 1) * _episodesPerPage;
    final endIdx = (startIdx + _episodesPerPage).clamp(0, totalEps);
    final pagedEps =
        totalEps > 0 ? _currentEps.sublist(startIdx, endIdx) : [];

    final currentSourceName = widget.serverSources.isNotEmpty &&
            _selectedSource < widget.serverSources.length
        ? (widget.serverSources[_selectedSource]['name'] ?? '').toString()
        : 'Server';

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1E2026),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                SvgPicture.asset(
                  'assets/svg_phimchitiet/download-cloud-svgrepo-com.svg',
                  width: 22,
                  height: 22,
                  colorFilter: const ColorFilter.mode(
                      AppTheme.accent, BlendMode.srcIn),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Tải phim về máy',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // Server source selector
          if (widget.serverSources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.dns_rounded,
                      color: AppTheme.textMuted, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    widget.movieName,
                    style: const TextStyle(
                        color: AppTheme.textSub, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  // Source dropdown
                  PopupMenuButton<int>(
                    onSelected: (index) {
                      setState(() {
                        _selectedSource = index;
                        _selectedSourceServer = 0;
                        _episodePage = 1;
                      });
                    },
                    offset: const Offset(0, 30),
                    color: AppTheme.bgCard,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    itemBuilder: (ctx) => List.generate(
                        widget.serverSources.length, (index) {
                      final isActive = index == _selectedSource;
                      final sourceLabel =
                          (widget.serverSources[index]['name'] ?? '')
                              .toString();
                      final totalEpsSource =
                          widget.serverSources[index]['totalEps'] ?? 0;
                      return PopupMenuItem<int>(
                        value: index,
                        child: Row(
                          children: [
                            if (isActive)
                              const Icon(Icons.check_rounded,
                                  color: Color(0xFFF5E6B8), size: 16),
                            if (isActive) const SizedBox(width: 6),
                            Text(
                              '$sourceLabel ($totalEpsSource tập)',
                              style: TextStyle(
                                color: isActive
                                    ? const Color(0xFFF5E6B8)
                                    : AppTheme.textPrimary,
                                fontSize: 13,
                                fontWeight: isActive
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.bgCard,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white, width: 1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(currentSourceName,
                              style: const TextStyle(
                                  color: AppTheme.textSub, fontSize: 12)),
                          const SizedBox(width: 4),
                          const Icon(Icons.keyboard_arrow_down_rounded,
                              color: AppTheme.textSub, size: 16),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Server sub-buttons
          if (_sourceServers.length > 1)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: List.generate(
                    _sourceServers.length > 2 ? 2 : _sourceServers.length,
                    (index) {
                  final isActive = index == _selectedSourceServer;
                  final sName =
                      (_sourceServers[index]['server_name'] ?? '').toString();
                  final serverEps =
                      (_sourceServers[index]['episodes'] as List<dynamic>?) ??
                          [];
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: index == 0 ? 8 : 0),
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedSourceServer = index;
                            _episodePage = 1;
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          padding:
                              const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: isActive
                                ? const Color(0xFFF5E6B8)
                                : AppTheme.bgCard,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isActive
                                  ? const Color(0xFFF5E6B8)
                                  : AppTheme.border,
                            ),
                          ),
                          child: Column(
                            children: [
                              Text(
                                sName,
                                style: TextStyle(
                                  color: isActive
                                      ? const Color(0xFF1A1100)
                                      : AppTheme.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              Text(
                                '(${serverEps.length} tập)',
                                style: TextStyle(
                                  color: isActive
                                      ? const Color(0xFF1A1100)
                                          .withValues(alpha: 0.6)
                                      : AppTheme.textMuted,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          const Divider(color: Colors.white10, height: 1),
          // Pagination
          if (totalPages > 1)
            SizedBox(
              height: 36,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: totalPages,
                itemBuilder: (_, pageIdx) {
                  final pageNum = pageIdx + 1;
                  final isActive = pageNum == _episodePage;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 3, vertical: 4),
                    child: GestureDetector(
                      onTap: () =>
                          setState(() => _episodePage = pageNum),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: isActive
                              ? AppTheme.accent.withValues(alpha: 0.2)
                              : AppTheme.bgCard,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isActive
                                ? AppTheme.accent
                                : AppTheme.border,
                          ),
                        ),
                        child: Text(
                          '$pageNum',
                          style: TextStyle(
                            color: isActive
                                ? AppTheme.accent
                                : AppTheme.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          // Episode list
          Flexible(
            child: pagedEps.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Chưa có tập phim',
                        style: TextStyle(
                            color: AppTheme.textSub, fontSize: 14),
                      ),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: pagedEps.length,
                    separatorBuilder: (_, __) => const Divider(
                        color: Colors.white10, height: 1, indent: 56),
                    itemBuilder: (context, index) {
                      final ep = pagedEps[index];
                      final epName =
                          (ep['ep_name'] ?? ep['name'] ?? '').toString();
                      final epId = ep['id'];
                      final isDl =
                          _downloadService.isDownloaded(widget.movieId, epId);
                      final isDling = _downloadService.isDownloading(
                          widget.movieId, epId);
                      final dlKey = '${widget.movieId}_$epId';
                      final progress = _progressMap[dlKey] ?? 0.0;

                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                // Leading icon
                                isDl
                                    ? const Icon(Icons.check_circle_rounded,
                                        color: Color(0xFF4CAF50), size: 22)
                                    : isDling
                                        ? SizedBox(
                                            width: 22,
                                            height: 22,
                                            child: Stack(
                                              alignment: Alignment.center,
                                              children: [
                                                CircularProgressIndicator(
                                                  value: progress > 0 ? progress : null,
                                                  strokeWidth: 2.5,
                                                  color: AppTheme.accent,
                                                  backgroundColor: AppTheme.bgSurface,
                                                ),
                                                if (progress > 0)
                                                  Text(
                                                    '${(progress * 100).toInt()}',
                                                    style: const TextStyle(
                                                      color: AppTheme.accent,
                                                      fontSize: 8,
                                                      fontWeight: FontWeight.w700,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          )
                                        : const Icon(Icons.download_rounded,
                                            color: AppTheme.textMuted, size: 22),
                                const SizedBox(width: 12),
                                // Title + subtitle
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        epName,
                                        style: TextStyle(
                                          color: isDl
                                              ? const Color(0xFF4CAF50)
                                              : Colors.white,
                                          fontSize: 14,
                                          fontWeight: isDl
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                      ),
                                      if (isDling && progress > 0)
                                        Text(
                                          'Đang tải: ${(progress * 100).toStringAsFixed(0)}%',
                                          style: const TextStyle(
                                              color: AppTheme.accent,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w500),
                                        )
                                      else
                                        FutureBuilder<int>(
                                          future: isDl
                                              ? Future.value(0)
                                              : _getEpisodeSize(ep),
                                          builder: (_, snap) {
                                            if (!snap.hasData || snap.data == 0) {
                                              return const SizedBox.shrink();
                                            }
                                            return Text(
                                              _formatSize(snap.data!),
                                              style: const TextStyle(
                                                  color: AppTheme.textMuted,
                                                  fontSize: 11),
                                            );
                                          },
                                        ),
                                    ],
                                  ),
                                ),
                                // Trailing button
                                isDl
                                    ? IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            color: Colors.redAccent, size: 20),
                                        onPressed: () {
                                          final item = _downloadService.getItem(
                                              widget.movieId, epId);
                                          if (item != null) {
                                            _downloadService.deleteItem(item);
                                            setState(() {});
                                          }
                                        },
                                      )
                                    : isDling
                                        ? IconButton(
                                            icon: const Icon(Icons.close,
                                                color: Colors.white54, size: 20),
                                            onPressed: () {
                                              final item = _downloadService.getItem(
                                                  widget.movieId, epId);
                                              if (item != null) {
                                                _downloadService.cancelDownload(item);
                                                setState(() {});
                                              }
                                            },
                                          )
                                        : IconButton(
                                            icon: SvgPicture.asset(
                                              'assets/svg_phimchitiet/download-cloud-svgrepo-com.svg',
                                              width: 20,
                                              height: 20,
                                              colorFilter:
                                                  const ColorFilter.mode(
                                                      AppTheme.accent,
                                                      BlendMode.srcIn),
                                            ),
                                            onPressed: () =>
                                                _confirmDownload(ep),
                                          ),
                              ],
                            ),
                            // Progress bar when downloading
                            if (isDling && progress > 0) ...[
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: LinearProgressIndicator(
                                  value: progress,
                                  backgroundColor: AppTheme.bgSurface,
                                  valueColor: const AlwaysStoppedAnimation<Color>(
                                      AppTheme.accent),
                                  minHeight: 3,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
          ),
          // Bottom safe area
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }
}
