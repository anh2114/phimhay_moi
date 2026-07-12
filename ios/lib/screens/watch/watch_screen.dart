import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:shimmer/shimmer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:dio/dio.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:phimhay_app/config/app_config.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/config/responsive.dart';
import 'package:phimhay_app/providers/auth_provider.dart';
import 'package:phimhay_app/services/api_client.dart';
import 'package:provider/provider.dart';
import 'package:phimhay_app/services/movie_service.dart';
import 'package:phimhay_app/services/activity_service.dart';
import 'package:phimhay_app/widgets/bottom_nav.dart';
import 'package:phimhay_app/widgets/header.dart';
import 'package:phimhay_app/widgets/svg_icon.dart';
import 'package:phimhay_app/screens/home/home_screen.dart';
import 'package:phimhay_app/screens/watch_party/watch_party_screen.dart';
import 'package:phimhay_app/screens/search/search_screen.dart';
import 'package:phimhay_app/screens/notification/notification_screen.dart';
import 'package:phimhay_app/screens/actors/actors_list_screen.dart';
import 'package:phimhay_app/screens/watch_room/watch_room_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:phimhay_app/services/srt_parser.dart';

/// Loại player hiện tại
enum _PlayerMode { hls, embed }

class WatchScreen extends StatefulWidget {
  final int movieId;
  final dynamic episodeId;   // id của episode đang phát
  final int serverIdx;
  final String? streamUrl;   // fallback nếu API không có
  final String? movieSlug;
  final String? movieTitle;
  final int initialPosition; // Giây đã xem (để seek khi mở)

  const WatchScreen({
    super.key,
    required this.movieId,
    required this.episodeId,
    this.serverIdx = 0,
    this.streamUrl,
    this.movieSlug,
    this.movieTitle,
    this.initialPosition = 0,
  });

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> with WidgetsBindingObserver {

  static bool get _isTablet {
    final size = WidgetsBinding.instance.window.physicalSize;
    final shortestSide = size.shortestSide / WidgetsBinding.instance.window.devicePixelRatio;
    return shortestSide >= 600;
  }

  /// iPad lớn (Pro 11"+): shortestSide > 750 → landscape-first khi xem phim
  static bool get _isLargeIpad {
    final size = WidgetsBinding.instance.window.physicalSize;
    final shortestSide = size.shortestSide / WidgetsBinding.instance.window.devicePixelRatio;
    return shortestSide > 750;
  }

  static void _restoreOrientations() {
    if (_isLargeIpad) {
      // iPad lớn: giữ landscape + portrait (user có thể xoay thoải mái)
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else if (_isTablet) {
      // iPad Mini: portrait lock giống phone
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
  }
  final Dio _dio = Dio();
  final MovieService _movieService = MovieService();
  InAppWebViewController? _webController;
  Player? _player;
  VideoController? _videoController;
  final GlobalKey _bpGlobalKey = GlobalKey();
  // Prefetch — giữ đơn giản ban đầu
  String _prefetchUrl = '';
  dynamic _prefetchEpId;
  static const _airplayChannel = MethodChannel('phimhay/airplay');

  bool _isLoading = true;
  String? _error;
  _PlayerMode _playerMode = _PlayerMode.embed;
  String _currentUrl = '';

  // Danh sách servers + episodes lấy từ API
  List<Map<String, dynamic>> _servers = [];
  List<Map<String, dynamic>> _flatEps = [];
  int _selectedServer = 0;
  dynamic _currentEpId;
  String _currentEpName = '';
  bool _hasSwitchedEp = false;
  bool _switchingServer = false;

  // Controls overlay
  bool _showControls = true;
  bool _showSkipIntro = false;
  bool _playerReady = false;

  // Custom player controls
  bool _isPlaying = false;
  bool _playPressed = false;
  double _playbackSpeed = 1.0;
  static const List<double> _speeds = [0.5, 1.0, 1.5, 2.0, 3.0];
  String _settingsPanel = 'main';
  String _selectedQuality = 'Auto';
  String _selectedSubtitleColor = '#FFFFFF';
  double _selectedSubtitleSize = 14.0;
  double _selectedSubtitleBgOpacity = 0.0;
  double _volume = 100.0;
  bool _isMuted = false;
  bool _isDragging = false;
  bool _isBuffering = false; // Đang buffer (seek, pause→play, network stall)
  bool _userPaused = false; // User chủ động pause (không phải network stall)
  bool _showVolumeInline = false;
  double _dragValue = 0;
  int _lastPositionUpdate = 0;
  Duration _currentPos = Duration.zero;
  Duration _currentDur = Duration.zero;

  // Đồng hồ hiện thị giờ VN (luôn hiện, không ẩn theo tap)
  Timer? _clockTimer;

  // Watch progress tracking
  Timer? _saveProgressTimer;
  Timer? _pendingServerSave; // Debounce save khi chuyển server nhanh
  int _currentPosition = 0;
  int _currentDuration = 0;
  Map<String, dynamic>? _savedProgress;

  // ★ Fix: stuck detector
  Timer? _stuckDetector;
  int _lastPositionForStuckCheck = 0;
  int _stuckTickCount = 0;

  // Episode pagination (100 per page)
  static const _epPerPage = 100;
  int _epPage = 1;       // Portrait grid page
  int _sheetEpPage = 1;  // Landscape episode sheet page

  int get _totalEpPages {
    final eps = _currentServerEps;
    if (eps.isEmpty) return 1;
    return (eps.length / _epPerPage).ceil();
  }

  List<Map<String, dynamic>> _getPageEps(int page) {
    final eps = _currentServerEps;
    final start = (page - 1) * _epPerPage;
    final end = start + _epPerPage;
    if (start >= eps.length) return [];
    return eps.sublist(start, end > eps.length ? eps.length : end);
  }

  int _detectEpPage(dynamic epId) {
    final eps = _currentServerEps;
    if (eps.length <= _epPerPage) return 1;
    for (int i = 0; i < eps.length; i++) {
      if (eps[i]['id'] == epId) return (i ~/ _epPerPage) + 1;
    }
    return 1;
  }

  @override
  void initState() {
    super.initState();
    _enableWakelockWithRetry(); // Chặn màn hình khóa khi xem phim
    _lockBrightness(); // Giữ độ sáng khi xem phim
    WidgetsBinding.instance.addObserver(this);
    _currentEpId = widget.episodeId;
    _showControlsWithAutoHide(); // hiện controls khi vào, auto ẩn sau 4s
    // Đồng hồ chỉ update khi landscape (tick mỗi 1s)
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isLandscape) setState(() {});
    });
    _selectedServer = widget.serverIdx;

    // Nếu có initialPosition → dùng ngay, không cần load từ API
    if (widget.initialPosition > 0) {
      _currentPosition = widget.initialPosition;
    }

    _fetchEpisodes();
    _loadWatchProgress();
    _setupPiPListener();

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // iPad lớn: tự chuyển landscape khi mở watch screen
    if (_isLargeIpad && !_isLandscape) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          SystemChrome.setPreferredOrientations([
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        }
      });
    }

    if (widget.initialPosition > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isLandscape) _toggleFullscreen();
      });
    }
  }

  // ── Load subtitles for current episode ──────────────────
  // Detect server có hardsub burned-in (vietsub, 1080p, 720p)
  // vs server không có hardsub (4K, ...) → cần load softsub
  bool get _isCurrentServerHardsub {
    if (_servers.isEmpty || _selectedServer >= _servers.length) return false;
    final name = (_servers[_selectedServer]['server_name'] ?? '').toString().toUpperCase();
    return name.contains('VIETSUB') || name.contains('1080P') || name.contains('720P');
  }

  bool get _isCurrentServer4K {
    if (_servers.isEmpty || _selectedServer >= _servers.length) return false;
    final name = (_servers[_selectedServer]['server_name'] ?? '').toString().toUpperCase();
    return name.contains('4K');
  }

  Future<void> _loadSubtitles(Map<String, dynamic> episode) async {
    final slug = widget.movieSlug ?? '';
    if (slug.isEmpty) {
      setState(() { _subtitles = []; _subtitleEnabled = false; });
      return;
    }

    // 1. Try subtitles.php API — hỗ trợ cả SRT và ASS
    try {
      final epSlug = (episode['ep_slug'] ?? episode['ep_name'] ?? '').toString();
      final res = await ApiClient.get('/subtitles.php', params: {'slug': slug, 'episode': epSlug});
      final data = res.data;
      if (data is Map<String, dynamic> && data['success'] == true) {
        final list = data['subtitles'] as List<dynamic>? ?? [];
        for (final item in list) {
          final subUrl = (item['url'] ?? '').toString();
          if (subUrl.isEmpty) continue;
          try {
            final subs = await _fetchSubtitleUrl(subUrl);
            if (mounted && subs.isNotEmpty) {
              _currentSubtitleUrl = subUrl;
              // Server hardsub → load phụ đề nhưng mặc định TẮT (stream đã có hardsub)
              // Server không hardsub (4K, ...) → auto-enable softsub
              setState(() {
                _subtitles = subs;
                _subtitleEnabled = !_isCurrentServerHardsub;
              });
              return;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}

    // 2. Fallback: try convention URLs (SRT + ASS + VTT)
    final urlsToTry = <String>[
      '${AppConfig.baseUrl}/art/$slug/${slug}_vi.srt',
      '${AppConfig.baseUrl}/art/$slug/${slug}.srt',
      '${AppConfig.baseUrl}/art/$slug/${slug}_vi.ass',
      '${AppConfig.baseUrl}/art/$slug/${slug}.ass',
      '${AppConfig.baseUrl}/art/$slug/${slug}_vi.vtt',
      '${AppConfig.baseUrl}/art/$slug/${slug}.vtt',
    ];

    for (final url in urlsToTry) {
      try {
        final subs = await _fetchSubtitleUrl(url);
        if (mounted && subs.isNotEmpty) {
          _currentSubtitleUrl = url;
          setState(() {
            _subtitles = subs;
            _subtitleEnabled = !_isCurrentServerHardsub;
          });
          return;
        }
      } catch (_) {}
    }
    // No subtitles found
    setState(() { _subtitles = []; _subtitleEnabled = false; });
  }

  /// Fetch subtitle file and auto-detect format from URL extension
  Future<List<SubtitleEntry>> _fetchSubtitleUrl(String url) async {
    final lower = url.toLowerCase();
    if (lower.endsWith('.ass') || lower.endsWith('.ssa')) {
      return _assParser.fetchAndParse(url);
    }
    if (lower.endsWith('.vtt')) {
      return _vttParser.fetchAndParse(url);
    }
    return _srtParser.fetchAndParse(url);
  }

  /// Get subtitle text for current position
  String? _getSubtitleForPosition(Duration position) {
    if (!_subtitleEnabled || _subtitles.isEmpty) return null;
    for (final sub in _subtitles) {
      if (position >= sub.start && position <= sub.end) {
        return sub.text;
      }
    }
    return null;
  }

  String get _effectiveServerName {
    if (_servers.isEmpty || _selectedServer >= _servers.length) return '';
    return (_servers[_selectedServer]['server_name'] ?? '').toString();
  }

  // ── Ad segment detection & auto-skip ──────────────────

  /// Fetch ad markers from API for current movie + server (with retry)
  Future<void> _loadAdMarkers(String m3u8Url, int movieId, String serverName) async {
    if (movieId <= 0 || m3u8Url.isEmpty) return;
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await ApiClient.get('/ad_markers.php', params: {
          'url': m3u8Url,
          'movie_id': '$movieId',
          'server_name': serverName,
        });
        final data = res.data;
        if (data is Map<String, dynamic> && data['success'] == true) {
          final ads = data['ads'] as List<dynamic>? ?? [];
          if (mounted && ads.isNotEmpty) {
            setState(() { _adMarkers = ads.cast<Map<String, dynamic>>(); });
            return;
          }
        }
      } catch (_) {}
      if (attempt == 0) await Future.delayed(const Duration(seconds: 2));
    }
  }

  /// Check if current position is inside an ad zone, seek past it
  void _checkAdSkip(Duration position) {
    if (_adMarkers.isEmpty || _adSkipCooldown || _isSeeking) return;
    final pos = position.inSeconds;

    // Detect ad playing: position jumped backward > 20s (ad stream starts at 0)
    if (_lastPositionBeforeAd > 20 && pos < 10 && (_lastPositionBeforeAd - pos) > 20) {
      // Find which ad zone we were near
      for (final ad in _adMarkers) {
        final adStart = (ad['start_time'] as num?)?.toInt() ?? 0;
        final adDur = (ad['duration'] as num?)?.toInt() ?? 0;
        final adEnd = adStart + adDur;
        final confidence = (ad['confidence'] as num?)?.toDouble() ?? 0.0;

        if (_lastPositionBeforeAd >= adStart - 10 && _lastPositionBeforeAd <= adEnd + 10 && confidence >= 0.3) {
          // Seek to movie timeline position AFTER the ad (not ad stream position)
          final seekTo = adEnd;
          _adSkipCooldown = true;
          _seekTargetTime = seekTo;
          _player!.seek(Duration(seconds: seekTo));
          if (mounted) setState(() {});
          Future.delayed(const Duration(milliseconds: _adSkipCooldownMs), () {
            if (mounted) _adSkipCooldown = false;
          });
          return;
        }
      }
      // No matching ad marker — just seek past where we were
      _adSkipCooldown = true;
      _seekTargetTime = _lastPositionBeforeAd + 30;
      _player!.seek(Duration(seconds: _lastPositionBeforeAd + 30));
      if (mounted) setState(() {});
      Future.delayed(const Duration(milliseconds: _adSkipCooldownMs), () {
        if (mounted) _adSkipCooldown = false;
      });
    }

    _lastPositionBeforeAd = pos;
  }

  /// Report missed ad to crowdsource DB
  void _reportMissedAd(int startTime) {
    final movieId = widget.movieId;
    if (movieId <= 0) return;
    try {
      ApiClient.dio.post('/ad_markers.php?action=report', data: {
        'movie_id': '$movieId',
        'server_name': _effectiveServerName,
        'report_type': 'missed_ad',
        'start_time': '$startTime',
      });
    } catch (_) {}
  }

  /// Build subtitle zone — overlay trên video
  /// Positioned ở TRÊN cùng để tránh đè hardsub (thường ở dưới)
  Widget _buildSubtitleZone() {
    if (!_subtitleEnabled || _subtitles.isEmpty || _playerMode != _PlayerMode.hls) {
      return const SizedBox.shrink();
    }
    final text = _getSubtitleForPosition(_currentPos);
    if (text == null) return const SizedBox.shrink();

    final colorHex = int.parse('0xFF${_selectedSubtitleColor.substring(1)}');

    return Positioned(
      top: 48,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(_selectedSubtitleBgOpacity),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Color(colorHex),
            fontSize: _selectedSubtitleSize,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
      ),
    );
  }

  /// Chọn server mặc định thông minh:
  /// 1. Server có "4K" trong tên + tập mới nhất
  /// 2. Server có tập mới nhất
  /// 3. Server đầu tiên
  static int pickBestServer(List<Map<String, dynamic>> servers) {
    if (servers.isEmpty) return 0;
    int bestIdx = 0;
    int bestSort = -1;
    int best4kIdx = -1;
    int best4kSort = -1;
    for (int i = 0; i < servers.length; i++) {
      final name = (servers[i]['server_name'] ?? '').toString();
      final eps = servers[i]['episodes'] as List<dynamic>? ?? [];
      if (eps.isEmpty) continue;
      final lastEp = eps.last;
      final sortVal = (lastEp['sort_order'] ?? 0) as int;
      if (sortVal > bestSort) { bestSort = sortVal; bestIdx = i; }
      if (name.toUpperCase().contains('4K') && sortVal > best4kSort) {
        best4kSort = sortVal; best4kIdx = i;
      }
    }
    return best4kIdx >= 0 ? best4kIdx : bestIdx;
  }

  // ── Load watch progress từ DB ────────────────────────
  Future<void> _loadWatchProgress() async {
    if (widget.movieId <= 0) return;
    try {
      final progress = await _movieService.getWatchProgress(widget.movieId);
      if (progress != null && mounted) {
        _savedProgress = progress;
        // ★ FIX: Chỉ override position khi KHÔNG chọn tập cụ thể
        if (widget.initialPosition <= 0 && !(widget.episodeId != null && widget.episodeId > 0)) {
          _currentPosition = (progress['position'] as int?) ?? 0;
        }
        _currentDuration = (progress['duration'] as int?) ?? 0;

        // Nếu episodes đã load xong mà chưa restore → restore ngay
        if (_servers.isNotEmpty) {
          setState(() => _restoreFromProgress());
        }
      }
    } catch (_) {}
  }

  // ── Restore server/episode từ saved progress (gọi sau khi có episodes) ──
  void _restoreFromProgress() {
    // ★ FIX: Neu da chuyen tap trong watch screen → skip restore
    if (_hasSwitchedEp) return;
    // ★ FIX: Nếu user đã chọn cụ thể tập từ movie detail → skip restore
    if (widget.episodeId != null && widget.episodeId > 0) return;

    final progress = _savedProgress;
    if (progress == null || _servers.isEmpty) return;

    final savedSourceUrl = (progress['source_url'] as String?)?.trim() ?? '';
    final savedEpId = progress['episode_id'];
    final savedServerIdx = (progress['server_idx'] as int?) ?? 0;

    // Ưu tiên 1: Match source_url chính xác
    if (savedSourceUrl.isNotEmpty) {
      for (int si = 0; si < _servers.length; si++) {
        final eps = (_servers[si]['episodes'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
        for (final ep in eps) {
          final m3u8 = (ep['link_m3u8'] ?? '').toString().trim();
          final embed = (ep['link_embed'] ?? '').toString().trim();
          if (m3u8 == savedSourceUrl || embed == savedSourceUrl) {
            _selectedServer = si;
            _currentEpId = ep['id'];
            return;
          }
        }
      }
    }

    // Ưu tiên 2: Match episode_id trên bất kỳ server nào
    if (savedEpId != null && savedEpId > 0) {
      for (int si = 0; si < _servers.length; si++) {
        final eps = (_servers[si]['episodes'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
        final found = eps.where((e) => e['id'] == savedEpId).toList();
        if (found.isNotEmpty) {
          _selectedServer = si;
          _currentEpId = savedEpId;
          return;
        }
      }
    }

    // Fallback: dùng server_idx cũ
    if (savedServerIdx > 0 && savedServerIdx < _servers.length) {
      _selectedServer = savedServerIdx;
    }
  }

  // ── Save watch progress định kỳ ────────────────────
  void _startProgressTimer() {
    _saveProgressTimer?.cancel();
    _saveProgressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _saveCurrentProgress();
    });
  }

  // ★ Stuck detector — disabled cho media_kit (libmpv tự handle)
  void _startStuckDetector() {
    _stuckDetector?.cancel();
    // Media_kit/libmpv tự quản lý playback state, không cần stuck detector
  }

  // ★ Fix B: State sync — no longer needed, handled by _onBetterPlayerEvent

  // Lưu progress khi chuyển server — dùng giá trị đã capture (debounce-safe)
  Future<void> _saveServerSwitchProgress(int position, int serverIdx, dynamic epId) async {
    if (widget.movieId <= 0) return;
    if (_watchRoomActive) return;

    String? epSlug;
    final eps = _servers.isNotEmpty && serverIdx < _servers.length
        ? ((_servers[serverIdx]['episodes'] as List<dynamic>?) ?? [])
        : [];
    for (final ep in eps) {
      if (ep['id'] == epId) {
        epSlug = (ep['ep_slug'] ?? ep['slug'] ?? '').toString();
        break;
      }
    }

    await _movieService.saveWatchProgress(
      movieId: widget.movieId,
      episodeId: epId is int ? epId : null,
      epSlug: epSlug,
      serverIdx: serverIdx,
      position: position,
      duration: _currentDuration,
      sourceType: _playerMode == _PlayerMode.hls ? 'hls' : 'embed',
      sourceUrl: _currentUrl,
    );
    debugPrint('Watch: Saved server switch progress — pos=$position, server=$serverIdx');
  }

  // Lưu progress ngay lập tức với position cho trước (dùng khi chuyển server)
  Future<void> _saveProgressImmediate(int position) async {
    if (widget.movieId <= 0) return;
    if (_watchRoomActive) return;

    String? epSlug;
    final eps = _currentServerEps;
    for (final ep in eps) {
      if (ep['id'] == _currentEpId) {
        epSlug = (ep['ep_slug'] ?? ep['slug'] ?? '').toString();
        break;
      }
    }

    await _movieService.saveWatchProgress(
      movieId: widget.movieId,
      episodeId: _currentEpId is int ? _currentEpId : null,
      epSlug: epSlug,
      serverIdx: _selectedServer,
      position: position,
      duration: _currentDuration,
      sourceType: _playerMode == _PlayerMode.hls ? 'hls' : 'embed',
      sourceUrl: _currentUrl,
    );
  }

  Future<void> _saveCurrentProgress() async {
    if (widget.movieId <= 0) return;
    if (_watchRoomActive) return;
    if (!_seekCompleted && _currentPosition > 15) return;
    // Dedup: skip if save in-flight or too recent (< 3s)
    if (_isSaving) return;
    if (_lastSaveTime != null && DateTime.now().difference(_lastSaveTime!).inSeconds < 3) return;
    _isSaving = true;
    try {
    int pos = 0;
    int dur = 0;
    if (_playerMode == _PlayerMode.hls && _player != null) {
      pos = _currentPosition;
      dur = _currentDuration;
    } else if (_playerMode == _PlayerMode.embed && _webController != null) {
      try {
        final posResult = await _webController!.evaluateJavascript(
          source: "document.querySelector('video')?.currentTime || 0",
        );
        if (posResult != null) pos = (posResult as num).toInt();
        final durResult = await _webController!.evaluateJavascript(
          source: "document.querySelector('video')?.duration || 0",
        );
        if (durResult != null) dur = (durResult as num).toInt();
      } catch (_) {}
    }

    // Tìm ep_slug từ episode hiện tại
    String? epSlug;
    final eps = _currentServerEps;
    for (final ep in eps) {
      if (ep['id'] == _currentEpId) {
        epSlug = (ep['ep_slug'] ?? ep['slug'] ?? '').toString();
        break;
      }
    }

    // Luôn lưu (kể cả pos = 0) để cập nhật episode + server
    await _movieService.saveWatchProgress(
      movieId: widget.movieId,
      episodeId: _currentEpId is int ? _currentEpId : null,
      epSlug: epSlug,
      serverIdx: _selectedServer,
      position: pos,
      duration: dur > 0 ? dur : _currentDuration,
      sourceType: _playerMode == _PlayerMode.hls ? 'hls' : 'embed',
      sourceUrl: _currentUrl,
    );

    // Report activity to admin
    ActivityService.reportWatching(
      movieId: widget.movieId,
      episodeId: _currentEpId is int ? _currentEpId : null,
      epSlug: epSlug,
      serverIdx: _selectedServer,
      position: pos,
      duration: dur > 0 ? dur : _currentDuration,
      sourceType: _playerMode == _PlayerMode.hls ? 'hls' : 'embed',
    );

    // Cập nhật vị trí đã lưu
    _lastSavedPosition = pos;
    _lastSaveTime = DateTime.now();
    } finally {
      _isSaving = false;
    }
  }

  // ── Save khi thoát ───────────────────────────────────
  Future<void> _saveProgressOnExit() async {
    _saveProgressTimer?.cancel();
    await _saveCurrentProgress();
  }



  Future<void> _showAirPlayPicker() async {
    try {
      await _airplayChannel.invokeMethod('showRoutePicker');
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      if (_player != null) {
        _positionBeforePause = _currentPos.inSeconds;
        _saveCurrentProgress();
      }
    } else if (state == AppLifecycleState.resumed) {
      // Skip resume logic if PiP is active — native player handles playback
      if (_isPiPMode) return;

      _enableWakelockWithRetry();
      _lockBrightness();

      // ★ FIX: Restore audio session TRƯỚC rồi mới play
      // iOS cần time để audio session switch từ background → playback
      if (Platform.isIOS && _playerMode == _PlayerMode.hls) {
        _audioChannel.invokeMethod('configureForPlayback').then((_) {}, onError: (_) {});
      }

      if (_player != null && _playerMode == _PlayerMode.hls) {
        final restoreVol = _isMuted ? 0.0 : ((_volume > 0 ? _volume : 100.0));
        final pos = _positionBeforePause;
        // ★ FIX: Capture wasPlaying BEFORE any delay — iOS may reset player state
        final wasPlaying = pos > 0; // If we had a position, we were playing

        // ★ FIX: Delay 500ms trên iOS (hệ thống cần time stabilize sau background)
        final delay = Platform.isIOS
            ? const Duration(milliseconds: 500)
            : const Duration(milliseconds: 300);

        Future.delayed(delay, () {
          if (!mounted || _player == null) return;

          // Restore volume + speed
          _player!.setVolume(restoreVol);
          if (_playbackSpeed != 1.0) _player!.setRate(_playbackSpeed);

          // ★ FIX: Always seek back if position was saved, then play
          if (pos > 5 && _currentPosition < 3) {
            _player!.seek(Duration(seconds: pos)).then((_) {
              if (mounted) _player!.play();
            });
          } else if (wasPlaying) {
            // ★ FIX: Always try to resume — player might be in stuck state
            _player!.play();
          }
        });
      } else if (_playerMode == _PlayerMode.embed && _webController != null) {
        // WebView embed — resume play
        final wasPlaying = _isPlaying;
        Future.delayed(const Duration(milliseconds: 300), () {
          if (!mounted || _webController == null) return;
          if (wasPlaying) {
            _webController!.evaluateJavascript(
              source: "document.querySelector('video')?.play();",
            );
          }
        });
      }
    }
  }

  @override
  void dispose() {
    // Restore wakelock và brightness
    try { WakelockPlus.disable(); } catch (_) {}
    _unlockBrightness(); // Restore độ sáng gốc
    // Restore system UI
    try { SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge); } catch (_) {}
    _healthCheckTimer?.cancel();
    _autoHideControlsTimer?.cancel();
    _clockTimer?.cancel();
    _doubleTapTimer?.cancel();
    _brightnessTimer?.cancel();
    _pendingServerSave?.cancel();
    _seekRetryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _saveProgressOnExit();
    ActivityService.stopWatching();
    _restoreOrientations();
    _cancelPrefetch();
    _subPosition?.cancel();
    _subPlaying?.cancel();
    _subDuration?.cancel();
    _subCompleted?.cancel();
    _player?.dispose();
    _webController?.dispose();
    _pipChannel.setMethodCallHandler(null);
    super.dispose();
  }

  // ── Brightness lock ─────────────────────────────────
  // Giữ nguyên brightness khi xem phim (giống YouTube)
  // Không ép max — chỉ khóa để OS auto-brightness không thay đổi
  Timer? _brightnessTimer;

  /// Enable wakelock với retry — tránh màn hình tối khi fail
  Future<void> _enableWakelockWithRetry() async {
    for (int i = 0; i < 3; i++) {
      try {
        await WakelockPlus.enable();
        return; // Thành công → thoát
      } catch (_) {
        // Retry sau 1s
        if (i < 2) await Future.delayed(const Duration(seconds: 1));
      }
    }
    // Nếu fail cả 3 lần → thử setSystemUIOverlayStyle để giữ màn hình
    try {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (_) {}
  }

  Future<void> _lockBrightness() async {
    try {
      _originalBrightness = await ScreenBrightness().current;
      // Nếu brightness quá thấp (< 0.1) → set về 0.5 để tránh tối đen
      if (_originalBrightness < 0.1) {
        _originalBrightness = 0.5;
        await ScreenBrightness().setScreenBrightness(0.5);
      }
      // Periodic timer chống OS auto-brightness override
      _brightnessTimer?.cancel();
      _brightnessTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        if (_brightnessLocked && mounted) {
          try {
            final current = await ScreenBrightness().current;
            // Chỉ set lại nếu brightness bị thay đổi (OS auto-brightness)
            if ((current - _originalBrightness).abs() > 0.05) {
              await ScreenBrightness().setScreenBrightness(_originalBrightness);
            }
          } catch (_) {}
        }
      });
      _brightnessLocked = true;
    } catch (_) {}
  }

  Future<void> _unlockBrightness() async {
    if (!_brightnessLocked) return;
    _brightnessTimer?.cancel();
    _brightnessTimer = null;
    try {
      await ScreenBrightness().setScreenBrightness(_originalBrightness);
      _brightnessLocked = false;
    } catch (_) {}
  }

  // ── PiP (Picture-in-Picture) ──────────────────────────
  void _setupPiPListener() {
    _pipChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPiPModeChanged':
          final isPiP = call.arguments as bool;
          if (mounted) {
            setState(() => _isPiPMode = isPiP);
            if (isPiP) {
              // PiP ON — hide controls, pause Flutter player
              _showControls = false;
              _autoHideControlsTimer?.cancel();
              _player?.pause();
              _webController?.evaluateJavascript(
                source: "document.querySelector('video')?.pause();",
              );
            }
          }
          break;
        case 'onPiPRestore':
          // PiP ended — restore Flutter player
          final args = call.arguments as Map<dynamic, dynamic>?;
          final position = args?['position'] as int? ?? 0;
          if (mounted) {
            setState(() => _isPiPMode = false);
            // Resume player at position
            if (_playerMode == _PlayerMode.hls && _player != null) {
              // Always restore audio session before playing
              if (Platform.isIOS) {
                _audioChannel.invokeMethod('configureForPlayback').then((_) {}, onError: (_) {});
              }
              _currentPosition = position;
              _performSeekRetry(position);
              _player!.play();
            } else if (_playerMode == _PlayerMode.embed && _webController != null) {
              if (position > 0) {
                _webController!.evaluateJavascript(
                  source: "var v=document.querySelector('video'); if(v){v.currentTime=$position; v.play();}",
                );
              }
            }
          }
          break;
        case 'onPiPError':
          if (mounted) {
            final error = call.arguments?.toString() ?? 'Unknown error';
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('PiP failed: $error'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 3),
              ),
            );
          }
          break;
        case 'onPiPLog':
          // Native debug logs — ignore in production
          break;
      }
    });
  }

  Future<void> _enterPiP() async {
    try {
      // Save current position first
      await _saveCurrentProgress();

      int position = 0;
      String url = _currentUrl;

      if (_playerMode == _PlayerMode.hls && _player != null) {
        position = _currentPosition;
      } else if (_playerMode == _PlayerMode.embed && _webController != null) {
        try {
          final posResult = await _webController!.evaluateJavascript(
            source: "document.querySelector('video')?.currentTime || 0",
          );
          if (posResult != null) position = (posResult as num).toInt();
        } catch (_) {}
      }

      if (url.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No video to PiP'), backgroundColor: Colors.orange),
        );
        return;
      }

      // iOS PiP: dùng proxy URL (IP trực tiếp, bypass DNS)
      String pipUrl = url;
      if (Platform.isIOS && !url.contains('hls_proxy.php')) {
        pipUrl = AppConfig.proxyHlsFullUrl(url);
      }

      debugPrint('[PiP] Sending URL: $pipUrl');

      final result = await _pipChannel.invokeMethod('enterPiP', {
        'url': pipUrl,
        'position': position,
        'headers': {
          'Referer': AppConfig.baseUrl,
          'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
        },
      });

      if (result != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không thể vào chế độ PiP'), backgroundColor: Colors.orange),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi PiP: $e'), backgroundColor: Colors.red),
      );
    }
  }

  // ── Double-click visual feedback ─────────────────────
  void _showDoubleTapFeedback(bool isRight) {
    _doubleTapTimer?.cancel();
    setState(() {
      if (isRight) {
        _showDoubleTapRight = true;
        _showDoubleTapLeft = false;
      } else {
        _showDoubleTapLeft = true;
        _showDoubleTapRight = false;
      }
      _doubleTapProgress = 1.0;
    });
    // Fade out animation
    _doubleTapTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() { _showDoubleTapLeft = false; _showDoubleTapRight = false; });
    });
  }

  // ── Long-press 2x speed ─────────────────────────────
  void _onLongPressStart() {
    _speedBeforeLongPress = _playbackSpeed;
    _isLongPressSpeedUp = true;
    _player?.setRate(2.0);
    setState(() {});
  }

  void _onLongPressEnd() {
    _isLongPressSpeedUp = false;
    _player?.setRate(_speedBeforeLongPress);
    setState(() {});
  }

  // ── Fetch episodes ────────────────────────────────
  Future<void> _fetchEpisodes() async {
    if (widget.movieId <= 0) {
      _initFallbackPlayer();
      return;
    }
    try {
      final res = await _dio.get(
        '${AppConfig.apiUrl}/movie_episodes.php',
        queryParameters: {'movie_id': widget.movieId},
      );
      final data = res.data as Map<String, dynamic>;
      final rawServers  = (data['servers']  as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
      final rawEpisodes = (data['episodes'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];

      if (!mounted) return;

      _servers = rawServers;
      _flatEps = rawEpisodes;

      // Chọn server mặc định thông minh (4K + tập mới nhất)
      if (_servers.isNotEmpty && widget.serverIdx == 0) {
        _selectedServer = pickBestServer(_servers);
      }

      // Không check health — tất cả nguồn đều sống (mobile HLS chạy được hết)
      // Reset status từ DB → tất cả là 'ok'
      for (final s in _servers) {
        s['status'] = 'ok';
      }

      if (_selectedServer >= _servers.length) _selectedServer = 0;

      setState(() {});

      // Restore server/episode từ saved progress (sau khi có episodes)
      _restoreFromProgress();

      // Play ngay
      _initPlayerFromEpisode();
    } catch (_) {
      if (!mounted) return;
      _initFallbackPlayer();
    }
  }

  void _initFallbackPlayer() {
    final url = (widget.streamUrl ?? '').trim();
    if (url.isNotEmpty) {
      _currentUrl = url;
      final isM3u8 = url.contains('.m3u8');
      if (isM3u8) {
        _initPlayer(url);
      }
      if (mounted) setState(() { _playerMode = isM3u8 ? _PlayerMode.hls : _PlayerMode.embed; _isLoading = false; });
    } else {
      // Không có tập + không có streamUrl → load trang web phim (giống browser)
      final movieUrl = '${AppConfig.baseUrl}/phim/${widget.movieSlug ?? ''}';
      _currentUrl = movieUrl;
      if (mounted) setState(() { _playerMode = _PlayerMode.embed; _isLoading = false; });
    }
  }

  void _initPlayerFromEpisode() {
    final eps = _currentServerEps;
    Map<String, dynamic>? currentEp;
    if (eps.isNotEmpty) {
      try {
        currentEp = eps.firstWhere(
          (e) => e['id'] == _currentEpId || e['ep_name'] == _currentEpId,
        );
      } catch (_) {}
      currentEp ??= eps.isNotEmpty ? eps[0] : null;
    }

    if (currentEp != null) {
      _currentEpId = currentEp['id'];
      _currentEpName = (currentEp['ep_name'] ?? currentEp['name'] ?? '').toString();
      _epPage = _detectEpPage(_currentEpId);
      _sheetEpPage = _epPage;
      final m3u8 = (currentEp['link_m3u8'] ?? '').toString().trim();
      final embed = (currentEp['link_embed'] ?? '').toString().trim();
      _currentEmbedUrl = embed; // lưu để fallback khi HLS fail
      _loadSubtitles(currentEp);
      // Load ad markers for auto-skip
      if (m3u8.isNotEmpty) {
        _loadAdMarkers(m3u8, widget.movieId, _effectiveServerName);
      }

      // Ưu tiên HLS cho tất cả (mobile chạy được hết)
      if (m3u8.isNotEmpty) {
        _currentUrl = m3u8;
        _initPlayer(m3u8);
        if (mounted) setState(() { _playerMode = _PlayerMode.hls; _isLoading = false; });
      } else if (embed.isNotEmpty) {
        _currentUrl = embed;
        if (mounted) setState(() { _playerMode = _PlayerMode.embed; _isLoading = false; });
      } else {
        _initFallbackPlayer();
      }
    } else {
      _initFallbackPlayer();
    }
  }

  Timer? _healthCheckTimer;
  String _currentEmbedUrl = ''; // fallback embed URL cho episode hiện tại

  int _lastSavedPosition = 0; // Track vị trí đã lưu để detect seek
  int _lastUiUpdate = 0; // Throttle UI updates
  bool _seekCompleted = false; // Flag để track seek đã hoàn thành
  Timer? _seekRetryTimer;
  bool _watchRoomActive = false; // Watch room đang mở → chặn save
  int _positionBeforePause = 0; // Vị trí trước khi app vào background
  int _seekTargetTime = 0;
  bool _isSaving = false; // Dedup concurrent save requests
  DateTime? _lastSaveTime; // Minimum interval between saves

  int _lastSeekByUser = 0;
  bool _isSeeking = false; // Đang seek → hiện buffering

  // ── Subtitles ──
  final SrtParser _srtParser = SrtParser();
  final AssParser _assParser = AssParser();
  final VttParser _vttParser = VttParser();
  List<SubtitleEntry> _subtitles = [];
  bool _subtitleEnabled = false;
  String? _currentSubtitleUrl;

  // ── Ad segment detection & auto-skip ──
  List<Map<String, dynamic>> _adMarkers = [];
  bool _adSkipCooldown = false;
  bool _adReportedCurrentAd = false;
  static const int _adSkipCooldownMs = 3000;
  int _lastPositionBeforeAd = 0; // Track position before ad jump

  /// Show ad duration when inside ad zone, else total duration
  Duration get _effectiveDur {
    if (_adMarkers.isEmpty) return _currentDur;
    final pos = _currentPosition;
    // If position jumped to near 0 from a high value → ad is playing
    // Show remaining ad duration based on where we were
    if (pos < 10 && _lastPositionBeforeAd > 30) {
      for (final ad in _adMarkers) {
        final adStart = (ad['start_time'] as num?)?.toInt() ?? 0;
        final adDur = (ad['duration'] as num?)?.toInt() ?? 0;
        final adEnd = adStart + adDur;
        if (_lastPositionBeforeAd >= adStart && _lastPositionBeforeAd <= adEnd + 10) {
          return Duration(seconds: adDur);
        }
      }
    }
    return _currentDur;
  }

  // ── Brightness lock ──
  double _originalBrightness = 1.0;
  bool _brightnessLocked = false;

  // ── PiP (Picture-in-Picture) — Android only ──
  // iOS PiP暂不支持 (AVPlayer proxy issues with m3u8 streams)
  static const _pipChannel = MethodChannel('phimhay/pip');
  bool _isPiPMode = false;

  // ── Double-click visual feedback ──
  bool _showDoubleTapLeft = false;
  bool _showDoubleTapRight = false;
  Timer? _doubleTapTimer;
  double _doubleTapProgress = 0;

  // ── Long-press 2x speed ──
  bool _isLongPressSpeedUp = false;
  double _speedBeforeLongPress = 1.0;

  // ── Aspect ratio ──
  static const List<double?> _aspectRatios = [null, 16/9, 4/3, 1/1];
  static const List<String> _aspectRatioLabels = ['Tự động', '16:9', '4:3', '1:1'];
  int _aspectRatioIndex = 0;
  double? _videoAspectRatio; // Detected from video tracks

  // ── Screen lock ──
  bool _isScreenLocked = false;

  void _cycleAspectRatio() {
    _aspectRatioIndex = (_aspectRatioIndex + 1) % _aspectRatios.length;
    setState(() {});
  }

  // _setupPlayerSubscriptions() removed — replaced by _onBetterPlayerEvent in BetterPlayerConfiguration

  StreamSubscription? _subPosition;
  StreamSubscription? _subPlaying;
  StreamSubscription? _subDuration;
  StreamSubscription? _subCompleted;

  void _initPlayerStreams() {
    _subPosition?.cancel();
    _subPlaying?.cancel();
    _subDuration?.cancel();
    _subCompleted?.cancel();

    _subPosition = _player!.stream.position.listen((pos) {
      if (!mounted) return;

      _currentPos = pos;
      _currentPosition = pos.inSeconds;

      // ★ Auto-skip ad segments
      if (_adMarkers.isNotEmpty && _playerMode == _PlayerMode.hls) {
        _checkAdSkip(pos);
      }

      // ★ Subtitle cần update nhanh (mỗi frame) để ẩn đúng lúc khi cue kết thúc
      if (_subtitleEnabled && _subtitles.isNotEmpty) {
        setState(() {});
      } else {
        // ★ Throttle UI khác mỗi 500ms — progress bar, time display
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastUiUpdate > 500) {
          _lastUiUpdate = now;
          setState(() {});
        }
      }

      // Auto-save progress mỗi 10s
      final diff = (_currentPosition - _lastSavedPosition).abs();
      if (diff > 10 && _currentPosition > 0) {
        _lastSavedPosition = _currentPosition;
        _saveCurrentProgress();
      }
      if (_currentDuration > 0 && _currentPosition >= _currentDuration - 30) {
        _startPrefetch();
      }
      _showSkipIntro = _currentPosition >= 10 && _currentPosition <= 120;
    });

    _subPlaying = _player!.stream.playing.listen((playing) {
      if (mounted) {
        final wasPlaying = _isPlaying;
        setState(() => _isPlaying = playing);
        // Nếu user chủ động pause → không hiện spinner
        if (!playing && wasPlaying && _playerReady && !_isSeeking && !_userPaused) {
          setState(() => _isBuffering = true);
        }
        // Nếu start play lại → hết buffer, clear userPaused
        if (playing) {
          setState(() {
            _isBuffering = false;
            _userPaused = false;
          });
        }
      }
    });

    _subDuration = _player!.stream.duration.listen((dur) {
      if (mounted && dur.inSeconds > 0) {
        setState(() {
          _currentDur = dur;
          _currentDuration = dur.inSeconds;
        });
      }
    });

    _subCompleted = _player!.stream.completed.listen((completed) {
      if (completed) {

      }
    });

    // Listen to player stream for video dimension detection
    _player!.stream.width.listen((w) {
      if (!mounted || w == null || w <= 0) return;
      final h = _player!.state.height;
      if (h != null && h > 0) {
        final ratio = w / h;
        if (_videoAspectRatio != ratio) {
          setState(() => _videoAspectRatio = ratio);
        }
      }
    });
    _player!.stream.height.listen((h) {
      if (!mounted || h == null || h <= 0) return;
      final w = _player!.state.width;
      if (w != null && w > 0) {
        final ratio = w / h;
        if (_videoAspectRatio != ratio) {
          setState(() => _videoAspectRatio = ratio);
        }
      }
    });
  }

  static const _audioChannel = MethodChannel('phimhay_app/audio');

  void _initPlayer(String url) {
    // ★ FIX: Cancel streams TRƯỚC dispose — dispose có thể emit position=0
    _subPosition?.cancel();
    _subPlaying?.cancel();
    _subDuration?.cancel();
    _subCompleted?.cancel();
    _seekRetryTimer?.cancel();

    // ★ FIX: Capture target position NGAY SAU khi cancel streams
    // mà TRƯỚC KHI dispose player (dispose có thể emit event cuối = 0)
    final targetPosition = _currentPosition;


    _player?.dispose();
    _player = null;
    _healthCheckTimer?.cancel();
    _playerReady = false;

    String playUrl = url;

    // ★ Proxy m3u8 — strip ad segments + rewrite URLs (mobile only)
    if (!kIsWeb && url.contains('.m3u8')) {
      playUrl = AppConfig.proxyM3u8Url(url);
    }

    final headers = <String, String>{};
    if (!kIsWeb) {
      headers['Referer'] = AppConfig.baseUrl;
      headers['User-Agent'] = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    }

    // ★ FIX: Configure iOS audio session cho video playback TRƯỚC KHI tạo player
    // Nếu không set → silent switch mute audio, hoặc audio không phát
    if (Platform.isIOS) {
      _audioChannel.invokeMethod('configureForPlayback').then((_) {}, onError: (_) {});
    }

    final startPos = _currentPosition > 0 ? Duration(seconds: _currentPosition) : Duration.zero;

    // Tạo media_kit Player
    _player = Player();
    _videoController = VideoController(_player!);

    // ★ FIX: Config hardware acceleration cho smoother playback
    // media_kit tự handle GPU decoder trên mobile

    // Lắng nghe state changes
    _initPlayerStreams();

    setState(() {
      _playerReady = false;
      _isLoading = true;
      _isSeeking = false;
    });

    // Open (play) URL
    _player!.open(
      Media(playUrl, httpHeaders: headers),
      play: true,
    ).then((_) {
      if (!mounted) return;
      setState(() {
        _playerReady = true;
        _isLoading = false;
      });

      final userVol = _isMuted ? 0.0 : (_volume > 0 ? _volume : 100.0);
      _player!.setVolume(userVol);

      // Restore playback speed
      if (_playbackSpeed != 1.0) {
        _player!.setRate(_playbackSpeed);
      }

      if (targetPosition > 0 && !_seekCompleted) {
        _performSeekRetry(targetPosition);
      }

      // Pre-buffer PiP player trên iOS (sau khi video bắt đầu play)
      if (Platform.isIOS && _playerMode == _PlayerMode.hls) {
        final pipUrl = playUrl.contains('hls_proxy.php') ? playUrl : AppConfig.proxyHlsFullUrl(playUrl);
        _pipChannel.invokeMethod('preparePiP', {
          'url': pipUrl,
          'position': _currentPosition,
          'headers': {
            'Referer': AppConfig.baseUrl,
            'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
          },
        });
      }
    }).catchError((e) {

      _fallbackToEmbed();
    });

    // Health check
    _healthCheckTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _player == null) return;
      if (_currentPosition == 0 && !_playerReady) {

        _fallbackToEmbed();
      }
    });

    _startProgressTimer();
  }

  /// ★ Seek — 1 lần ngay + 1 lần retry sau 2s nếu chưa tới target
  void _performSeekRetry(int targetSec) {
    _seekRetryTimer?.cancel();
    if (_seekCompleted || !mounted || _player == null) return;

    // ★ FIX: Đảm bảo volume restored trước khi seek
    final restoreVol = _isMuted ? 0.0 : ((_volume > 0 ? _volume : 100.0));
    _player!.setVolume(restoreVol);

    // Seek lần đầu
    _player!.seek(Duration(seconds: targetSec));

    // Retry 1 lần sau 2s — nếu player đã buffer đủ thì seek sẽ work
    _seekRetryTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _player == null || _seekCompleted) return;
      if ((_currentPosition - targetSec).abs() > 5) {
        _player!.seek(Duration(seconds: targetSec));
      }
      _seekCompleted = true;
      // ★ FIX: Đảm bảo play sau seek
      if (!_isPlaying) {
        _player!.play();
      }
    });
  }

  /// Parse m3u8 to calculate total duration from #EXTINF tags
  /// Used as fallback when native player doesn't report duration
  Future<void> _fetchM3u8Duration(String url, Map<String, String> headers) async {
    if (_currentDuration > 0) return; // already have duration
    try {
      final response = await _dio.get(
        url,
        options: Options(headers: headers, receiveTimeout: const Duration(seconds: 10)),
      );
      final content = response.data?.toString() ?? '';
      if (content.isEmpty || !content.contains('#EXTINF')) return;

      double totalSeconds = 0;
      final lines = content.split('\n');
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.startsWith('#EXTINF:')) {
          // Parse #EXTINF:6.000000, or #EXTINF:6.000000,
          final match = RegExp(r'#EXTINF:([\d.]+)').firstMatch(trimmed);
          if (match != null) {
            totalSeconds += double.parse(match.group(1)!);
          }
        }
      }

      if (totalSeconds > 0 && _currentDuration == 0 && mounted) {
        setState(() {
          _currentDur = Duration(seconds: totalSeconds.toInt());
          _currentDuration = totalSeconds.toInt();
        });
      }
    } catch (_) {}
  }

  /// Seek đến _currentPosition - gọi khi duration đã available
  Future<void> _seekToPosition() async {
    if (_seekCompleted || _currentPosition <= 15) return;

    _seekTargetTime = _currentPosition;
    _seekCompleted = true;

    // Fire seek immediately — position stream sẽ confirm arrival
    _player!.seek(Duration(seconds: _currentPosition)).then((_) {
      if (mounted) _player!.play();
    });
  }

  /// HLS fail → thử server khác (logged in) hoặc embed (logged out)
  void _fallbackToEmbed() {
    _healthCheckTimer?.cancel();
    if (!mounted) return;

    // Fallback embed trước, nếu không có → thử server khác
    if (_currentEmbedUrl.isNotEmpty) {
      setState(() {
        _playerMode = _PlayerMode.embed;
        _currentUrl = _currentEmbedUrl;
        _isLoading = true;
        _error = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('HLS không khả dụng, chuyển sang chế độ nhúng...'),
          duration: Duration(seconds: 2),
          backgroundColor: Colors.orange,
        ),
      );
    } else {
      _markBrokenAndSwitch();
    }
  }

  void _reportHealth(String status) {
    if (_servers.isEmpty || _selectedServer >= _servers.length) return;
    final serverName = _servers[_selectedServer]['server_name']?.toString() ?? '';
    if (serverName.isEmpty) return;
    _movieService.saveServerHealth(
      movieId: widget.movieId,
      episodeId: _currentEpId is int ? _currentEpId : null,
      serverName: serverName,
      status: status,
    );
  }

  void _markBrokenAndSwitch() {
    if (!mounted || _servers.isEmpty) return;

    for (int i = 0; i < _servers.length; i++) {
      if (i == _selectedServer) continue;
      setState(() {
        _selectedServer = i;
        _isLoading = true;
        _error = null;
      });
      _initPlayerFromEpisode();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nguồn lỗi, chuyển sang ${_servers[i]['server_name'] ?? 'nguồn khác'}...'),
          duration: const Duration(seconds: 2),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _error = 'Tất cả nguồn đều không hoạt động');
  }

  // ── Lấy episodes của server đang chọn ─────────────
  List<Map<String, dynamic>> get _currentServerEps {
    if (_servers.isNotEmpty && _selectedServer < _servers.length) {
      return (_servers[_selectedServer]['episodes'] as List<dynamic>?)
              ?.cast<Map<String, dynamic>>() ?? [];
    }
    if (_flatEps.isNotEmpty) {
      final sname = _servers.isNotEmpty
          ? (_servers[_selectedServer]['server_name'] ?? '')
          : '';
      if (sname.isNotEmpty) {
        return _flatEps.where((e) => e['server_name'] == sname).toList();
      }
      return _flatEps;
    }
    return [];
  }

  // ── Chuyển server — giữ nguyên vị trí xem ─────────
  void _switchServer(int newServerIdx) {
    if (newServerIdx == _selectedServer) return;
    if (newServerIdx < 0 || newServerIdx >= _servers.length) return;



    // Đánh dấu đang chuyển server
    _switchingServer = true;

    // Lấy vị trí hiện tại TRƯỚC KHI chuyển server
    int currentPosition = 0;
    if (_playerMode == _PlayerMode.hls && _player != null) {
      currentPosition = _currentPosition;
    } else if (_playerMode == _PlayerMode.embed && _webController != null) {
      currentPosition = _currentPosition;
    }
    if (currentPosition <= 0) currentPosition = _currentPosition;

    // Lưu NGAY position + server cũ trước khi setState thay đổi giá trị
    final posToSave = currentPosition;
    final serverToSave = _selectedServer;
    final epToSave = _currentEpId;

    // Cancel periodic save để tránh overwrite position mới
    _saveProgressTimer?.cancel();

    // Save IMMEDIATELY
    _saveServerSwitchProgress(posToSave, serverToSave, epToSave);

    // Tìm tập tương ứng trên server mới
    final currentEps = _currentServerEps;
    Map<String, dynamic>? matchingEp;

    if (_currentEpId != null && currentEps.isNotEmpty) {
      final currentEp = currentEps.where((e) => e['id'] == _currentEpId).toList();
      if (currentEp.isNotEmpty) {
        final currentSlug = (currentEp.first['ep_slug'] ?? '').toString();
        final currentName = (currentEp.first['ep_name'] ?? currentEp.first['name'] ?? '').toString();
        final currentIndex = currentEps.indexOf(currentEp.first);

        final newEps = (_servers[newServerIdx]['episodes'] as List<dynamic>?)
                ?.cast<Map<String, dynamic>>() ?? [];

        // Tìm theo ep_slug trước
        if (currentSlug.isNotEmpty) {
          final bySlug = newEps.where((e) => (e['ep_slug'] ?? '').toString() == currentSlug).toList();
          if (bySlug.isNotEmpty) matchingEp = bySlug.first;
        }
        // Fallback: tìm theo ep_name
        if (matchingEp == null && currentName.isNotEmpty) {
          final byName = newEps.where((e) => (e['ep_name'] ?? e['name'] ?? '').toString() == currentName).toList();
          if (byName.isNotEmpty) matchingEp = byName.first;
        }
        // Fallback: tìm theo index
        if (matchingEp == null && currentIndex < newEps.length) {
          matchingEp = newEps[currentIndex];
        }
      }
    }

    setState(() {
      _selectedServer = newServerIdx;
      _currentPosition = currentPosition;
      _epPage = 1;
      _sheetEpPage = 1;
    });

    if (matchingEp != null) {
      _switchEpisode(matchingEp, keepPosition: true);
    } else {
      _switchingServer = false;
    }
  }

  // ── Chuyển tập ────────────────────────────────────
  void _switchEpisode(Map<String, dynamic> ep, {bool keepPosition = false}) {
    _doSwitchEpisode(ep, keepPosition: keepPosition);
  }

  void _doSwitchEpisode(Map<String, dynamic> ep, {bool keepPosition = false}) {
    _hasSwitchedEp = true;
    _switchingServer = false;
    _startProgressTimer();

    // Capture position TRƯỚC khi reset state
    final savedPosition = keepPosition ? _currentPosition : 0;


    if (!keepPosition) _saveCurrentProgress();

    // Cancel prefetch
    if (_prefetchEpId != ep['id']) _cancelPrefetch();

    final epId = ep['id'];
    final m3u8 = (ep['link_m3u8'] ?? '').toString().trim();
    final embed = (ep['link_embed'] ?? '').toString().trim();
    _currentEmbedUrl = embed;

    final bool useHls = m3u8.isNotEmpty;
    final String url = m3u8.isNotEmpty ? m3u8 : embed;

    if (url.isEmpty) return;

    setState(() {
      _currentEpId = epId;
      _currentEpName = (ep['ep_name'] ?? ep['name'] ?? '').toString();
      _epPage = _detectEpPage(_currentEpId);
      _sheetEpPage = _epPage;
      _isLoading = true;
      _error = null;
      _currentUrl = url;
      _playerReady = false;
      _playerMode = useHls ? _PlayerMode.hls : _PlayerMode.embed;
      // LUÔN reset position, sẽ seek lại sau khi player ready
      _currentPosition = savedPosition;
      _lastSavedPosition = savedPosition;
      _seekTargetTime = savedPosition;
      _seekCompleted = false; // Luôn cần seek lại
      _subtitles = [];
      _adMarkers = []; // Reset ad markers for new episode
    });

    _loadSubtitles(ep);
    // Load ad markers for new episode
    if (url.isNotEmpty && useHls) {
      _loadAdMarkers(url, widget.movieId, _effectiveServerName);
    }

    if (useHls) {
      if (!_tryUsePrefetched(ep)) {
        _initPlayer(url);
      }
    }

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _isLoading) setState(() => _isLoading = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
  }

  // Auto ẩn controls sau 4s
  Timer? _autoHideControlsTimer;
  void _showControlsWithAutoHide() {
    _autoHideControlsTimer?.cancel();
    setState(() => _showControls = true);
    _autoHideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  // ── Build ──────────────────────────────────────────
  final GlobalKey _playerKey = GlobalKey();
  bool _isLandscape = false;

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;

    // Auto fullscreen khi xoay ngang
    if (isLandscape != _isLandscape) {
      _isLandscape = isLandscape;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isLandscape) {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        } else {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        }
      });
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: !isLandscape,
        left: !isLandscape,
        right: !isLandscape,
        bottom: !isLandscape,
        child: isLandscape
            ? Stack(children: [
                Positioned.fill(child: _buildPlayer(expandToFill: true)),
              ])
            : Column(children: [
                // Header
                Header(
                  onSearchTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen())),
                  onWatchPartyTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WatchPartyScreen())),
                  onNotificationTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationScreen())),
                  onActorsTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ActorsListScreen())),
                  onAccountTap: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomeScreen(initialIndex: 3))),
                ),
                // Player — Auto: detect video ratio, Fill: maximize, Manual: fixed ratio
                _buildPortraitPlayer(),
                // Info + Episodes (padding đáy cho BottomNav)
                Expanded(
                  child: Stack(
                    children: [
                      _buildInfoAndEpisodes(),
                      Positioned(
                        bottom: 0, left: 0, right: 0,
                        child: Builder(
                          builder: (context) {
                            final auth = context.watch<AuthProvider>();
                            return BottomNav(
                              currentIndex: -1,
                              onTabSelected: (index) {
                                Navigator.pushReplacement(
                                  context,
                                  MaterialPageRoute(builder: (_) => HomeScreen(initialIndex: index)),
                                );
                              },
                              avatarUrl: auth.isLoggedIn ? (() {
                                final raw = auth.user?['avatar']?.toString() ?? '';
                                return raw.isNotEmpty && !raw.startsWith('http') ? '${AppConfig.baseUrl}$raw' : raw;
                              })() : null,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ]),
      ),
    );
  }

  Future<void> _createWatchParty() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (!auth.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng đăng nhập để xem chung'), backgroundColor: Colors.orange),
      );
      return;
    }
    final movieId = widget.movieId;
    final epId = _currentEpId;
    if (movieId <= 0) return;

    // DỪNG video trước, rồi lấy position
    if (_playerMode == _PlayerMode.hls && _player != null) {
      _player!.pause();
      await Future.delayed(const Duration(milliseconds: 200));
    } else if (_playerMode == _PlayerMode.embed && _webController != null) {
      try {
        await _webController!.evaluateJavascript(
          source: "document.querySelector('video')?.pause();",
        );
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (_) {}
    }

    // Lấy position SAU khi pause
    int pos = 0;
    if (_playerMode == _PlayerMode.hls && _player != null) {
      pos = _currentPosition;
    } else if (_playerMode == _PlayerMode.embed && _webController != null) {
      try {
        final r = await _webController!.evaluateJavascript(
          source: "document.querySelector('video')?.currentTime || 0",
        );
        if (r != null) pos = (r as num).toInt();
      } catch (_) {}
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator(color: AppTheme.accent)),
    );
    try {
      final res = await ApiClient.post(
        '/watch_party.php',
        data: FormData.fromMap({
          'action': 'create_room',
          'movie_id': movieId,
          'episode_id': epId,
          'position': pos,
        }),
      );
      if (mounted) Navigator.pop(context);
      final data = res.data;
      if (data['success'] == true && data['room_code'] != null) {
        final roomCode = data['room_code'];

        // Chặn save + dừng timer/listener
        _watchRoomActive = true;
        _saveProgressTimer?.cancel();
        await _saveCurrentProgress();

        // Pause player NGAY
        _player?.pause();
        _webController?.evaluateJavascript(
          source: "document.querySelector('video')?.pause();",
        );

        // Mở WatchRoomScreen native — truyền position để seek ngay
        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => WatchRoomScreen(roomCode: roomCode, initialPosition: pos),
            ),
          );

          // Quay lại từ watch party → reload progress mới nhất + seek
          if (mounted) {
            _watchRoomActive = false;
            _startProgressTimer();
            _startStuckDetector();
            await _loadWatchProgress();
            if (_player != null && _currentPosition > 3) {
              _seekCompleted = false;
              await _player!.seek(Duration(seconds: _currentPosition));
              _seekCompleted = true;
              _lastSavedPosition = _currentPosition;
            }
          }
        }
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['error'] ?? 'Không thể tạo phòng')));
      }
    } catch (e) {
      if (mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lỗi kết nối'))); }
    }
  }

  // ── Info + Episodes (chỉ hiện ở portrait) ─────────
  Widget _buildInfoAndEpisodes() {
    return Column(
      children: [
        // Info bar
        Container(
          color: const Color(0xFF0D0F14),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Row(
            children: [
              GestureDetector(
                onTap: () {
                  Navigator.pop(context);
                },
                child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.movieTitle ?? '',
                  style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Nút xem chung
              GestureDetector(
                onTap: _createWatchParty,
                child: Container(
                  margin: const EdgeInsets.only(right: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppTheme.accent.withValues(alpha: 0.3)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.people_outline_rounded, color: AppTheme.accent, size: 14),
                    const SizedBox(width: 4),
                    const Text('Xem chung', style: TextStyle(color: AppTheme.accent, fontSize: 10, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
              // Badge player mode — luôn hiện để biết đang chạy HLS hay Embed
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _playerMode == _PlayerMode.hls ? Colors.green.withValues(alpha: 0.2) : const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _playerMode == _PlayerMode.hls ? 'HLS' : 'Embed',
                  style: TextStyle(
                    color: _playerMode == _PlayerMode.hls ? Colors.greenAccent : Colors.white38,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Server selector — hiện cho mọi user
        if (_servers.length > 1) _buildServerSelector(),
        const Divider(color: Color(0x22FFFFFF), height: 1),
        // Episode list header
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Row(
            children: [
              const Text('Chọn tập', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
              const Spacer(),
            ],
          ),
        ),
        // Episodes grid (with pagination inside)
        Expanded(
          child: _buildEpisodeGrid(),
        ),
      ],
    );
  }

  // ── Portrait player — fills available width, height from stream ratio ─────────
  Widget _buildPortraitPlayer() {
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;

    // Use detected video ratio, fallback to 2.35:1 (cinematic default)
    final ratio = _videoAspectRatio ?? (2.35);
    final videoH = screenW / ratio;

    // Cap height but allow generous space — video fills width naturally
    final maxH = screenH * 0.85;
    final clampedH = videoH.clamp(0.0, maxH);

    return SizedBox(
      width: double.infinity,
      height: clampedH,
      child: _buildPlayer(),
    );
  }

  // ── Player — hybrid HLS / WebView ─────────────────
  Widget _buildPlayer({bool expandToFill = false}) {
    // Manual ratio selected → apply everywhere (portrait + landscape)
    // Auto (index 0) + landscape → fill entire space
    final useAspectRatio = _aspectRatioIndex > 0;

    return Stack(
        fit: StackFit.expand,
        children: [
          // ── HLS native player (media_kit) ──
          if (_playerMode == _PlayerMode.hls && _videoController != null)
            AnimatedOpacity(
              opacity: _playerReady ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: useAspectRatio
                  ? Center(
                      child: AspectRatio(
                        aspectRatio: _aspectRatios[_aspectRatioIndex]!,
                        child: Video(controller: _videoController!, key: _bpGlobalKey, controls: NoVideoControls),
                      ),
                    )
                  : Video(controller: _videoController!, key: _bpGlobalKey, controls: NoVideoControls),
            ),

          // ── Subtitle overlay — đặt TRONG player stack ──
          if (_subtitleEnabled && _subtitles.isNotEmpty && _playerMode == _PlayerMode.hls)
            _buildSubtitleZone(),

          // ── Buffering indicator — đã chuyển sang YouTube-style ở dưới ──

          // ── WebView embed ──
          if (_playerMode == _PlayerMode.embed && _error == null)
            InAppWebView(
              key: ValueKey('embed_$_currentEpId'),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                allowUniversalAccessFromFileURLs: true,
                mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                useWideViewPort: true,
                loadWithOverviewMode: true,
                builtInZoomControls: false,
                displayZoomControls: false,
              ),
              initialUrlRequest: URLRequest(
                url: WebUri(_currentUrl.isNotEmpty
                    ? _currentUrl
                    : widget.streamUrl ?? '${AppConfig.baseUrl}/phim/${widget.movieSlug ?? ''}'),
              ),
              onWebViewCreated: (c) => _webController = c,
              onLoadStart: (_, __) { if (mounted) setState(() => _isLoading = true); },
              onLoadStop:  (_, __) {
                if (mounted) setState(() => _isLoading = false);
                if (_currentPosition > 15 && _webController != null) {
                  _webController!.evaluateJavascript(
                    source: "var v=document.querySelector('video'); if(v){v.currentTime=$_currentPosition; v.play().catch(()=>{});}",
                  );
                }
                _startProgressTimer();
                _reportHealth('ok');
              },
              onReceivedError: (_, __, ___) {
                if (mounted) setState(() { _error = 'Không thể tải video'; _isLoading = false; });
              },
            ),

          // ── Gesture zones: tap = show/hide controls, double-tap = seek, long-press = 2x ──
          // Only active when controls are HIDDEN — when controls visible, taps go to buttons
          if (_playerMode == _PlayerMode.hls && _playerReady && !_showControls)
            Stack(
              children: [
                Row(
                  children: [
                    // LEFT zone: tap, double-tap = lùi 10s, long-press = 2x
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () {
                          // Buffering → tap to pause (like YouTube)
                          if (_isBuffering && _isPlaying) {
                            _player?.pause();
                            setState(() { _isBuffering = false; _userPaused = true; });
                            return;
                          }
                          _showControlsWithAutoHide();
                        },
                        onDoubleTap: () {
                          final pos = _currentPos;
                          final target = max(0, pos.inSeconds - 10);
                          _seekTargetTime = target;
                          _lastSeekByUser = DateTime.now().millisecondsSinceEpoch;
                          if (mounted) setState(() {
                            _currentPos = Duration(seconds: target);
                            _isSeeking = true;
                          });
                          _player?.seek(Duration(seconds: target)).then((_) {
                            if (mounted) setState(() {
                              _isSeeking = false;

                            });
                          });
                          _showDoubleTapFeedback(false);
                        },
                        onLongPressStart: (_) => _onLongPressStart(),
                        onLongPressEnd: (_) => _onLongPressEnd(),
                        onLongPressCancel: () => _onLongPressEnd(),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    // CENTER zone: tap = toggle controls (or pause if buffering)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () {
                          if (_isBuffering && _isPlaying) {
                            _player?.pause();
                            setState(() { _isBuffering = false; _userPaused = true; });
                            return;
                          }
                          _showControlsWithAutoHide();
                        },
                        child: const SizedBox.expand(),
                      ),
                    ),
                    // RIGHT zone: tap, double-tap = tới 10s, long-press = 2x
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () {
                          if (_isBuffering && _isPlaying) {
                            _player?.pause();
                            setState(() { _isBuffering = false; _userPaused = true; });
                            return;
                          }
                          _showControlsWithAutoHide();
                        },
                        onDoubleTap: () {
                          final pos = _currentPos;
                          final target = pos.inSeconds + 10;
                          _seekTargetTime = target;
                          _lastSeekByUser = DateTime.now().millisecondsSinceEpoch;
                          if (mounted) setState(() {
                            _currentPos = Duration(seconds: target);
                            _isSeeking = true;
                          });
                          _player?.seek(Duration(seconds: target)).then((_) {
                            if (mounted) setState(() {
                              _isSeeking = false;
                              
                            });
                          });
                          _showDoubleTapFeedback(true);
                        },
                        onLongPressStart: (_) => _onLongPressStart(),
                        onLongPressEnd: (_) => _onLongPressEnd(),
                        onLongPressCancel: () => _onLongPressEnd(),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
                // ── Double-tap left feedback ──
                if (_showDoubleTapLeft)
                  Positioned(
                    left: 20,
                    top: 0, bottom: 0,
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: _showDoubleTapLeft ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.replay_10, color: Colors.white, size: 32),
                        ),
                      ),
                    ),
                  ),
                // ── Double-tap right feedback ──
                if (_showDoubleTapRight)
                  Positioned(
                    right: 20,
                    top: 0, bottom: 0,
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: _showDoubleTapRight ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.forward_10, color: Colors.white, size: 32),
                        ),
                      ),
                    ),
                  ),
                // ── Long-press 2x speed indicator ──
                if (_isLongPressSpeedUp)
                  Positioned(
                    top: 12,
                    left: 0, right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          '2x ▸',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
              ],
            ),

          // ── Custom overlay controls — chỉ hiện khi landscape + HLS ──
          if (_isLandscape && _playerMode == _PlayerMode.hls && _playerReady) ...[
            // Center controls render FIRST (behind everything)
            if (!_isScreenLocked && _showControls)
              Positioned(
                top: 0, bottom: 0, left: 0, right: 0,
                child: _buildCenterControls(),
              ),
            // Bottom bar before top bar (top bar is topmost)
            if (!_isScreenLocked && _showControls)
              Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomBar()),
            if (_showSkipIntro && !_isScreenLocked && _showControls)
              Positioned(bottom: 80, right: 12, child: _skipIntroButton()),
            // Top bar LAST = renders on top = receives taps first
            if (_showControls)
              Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),
          ],
          // ── Portrait mini controls — chỉ hiện khi portrait + HLS ──
          if (_showControls && !_isLandscape && _playerMode == _PlayerMode.hls && _playerReady)
            Positioned(bottom: 0, left: 0, right: 0, child: _buildPortraitMiniControls()),

          // ── Loading — YouTube-style buffering indicator ──
          if ((_isLoading && !_playerReady) || _isBuffering || _isSeeking)
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  // Tap to pause during buffering (like YouTube)
                  if (_isBuffering && _isPlaying) {
                    _player?.pause();
                    setState(() { _isBuffering = false; _userPaused = true; });
                  }
                },
                child: Container(
                  color: Colors.black26,
                  child: const Center(
                    child: SizedBox(
                      width: 48, height: 48,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 3,
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // ── Error ──
          if (_error != null)
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.white38),
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.white54, fontSize: 14)),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh, color: AppTheme.accent),
                  label: const Text('Thử lại', style: TextStyle(color: AppTheme.accent)),
                ),
              ]),
            ),

          // ── Subtitle overlay — moved to _buildSubtitleZone() ──

        ],
      );
  }

  Map<String, dynamic>? _getNextEpisode() {
    final eps = _currentServerEps;
    if (eps.isEmpty) return null;
    for (int i = 0; i < eps.length; i++) {
      if (eps[i]['id'] == _currentEpId && i + 1 < eps.length) {
        return eps[i + 1];
      }
    }
    return null;
  }

  // ── Prefetch: disabled for better_player_plus migration (can re-add later) ──
  void _startPrefetch() {
    // TODO: Re-implement prefetch with better_player_plus
  }

  void _cancelPrefetch() {
    _prefetchUrl = '';
    _prefetchEpId = null;
  }

  /// If prefetch match ep → swap player, skip init
  bool _tryUsePrefetched(Map<String, dynamic> ep) {
    // TODO: Re-implement prefetch with better_player_plus
    return false;
  }

  Widget _skipIntroButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_player == null) return;
        final current = _currentPosition;
        final target = current + 120;
        _seekTargetTime = target;
        if (mounted) setState(() => _currentPos = Duration(seconds: target));
        _player!.seek(Duration(seconds: target));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppSvgIcon('fast-forward.svg', size: 16, color: Colors.white),
            const SizedBox(width: 4),
            const Text(
              'Bỏ qua 2 phút',
              style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nextEpisodeButton() {
    final nextEp = _getNextEpisode();
    if (nextEp == null) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _switchEpisode(nextEp),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: AppSvgIcon('skip-forward.svg', size: 20, color: Colors.white),
      ),
    );
  }

  // ── Episode Sheet (fullscreen) ────────────────────────────

  /// Format episode name: "1" → "1", "01" → "01", "tập 1" → "1", "Tập tập 01" → "01"
  String _formatEpName(String raw) {
    var name = raw.trim();
    // Bỏ prefix "tập ", "Tập ", "TẬP " (có thể lặp nhiều lần)
    name = name.replaceAll(RegExp(r'^[Tt]ậ?p?\s*', caseSensitive: false), '').trim();
    // Nếu rỗng → trả về raw
    return name.isEmpty ? raw : name;
  }

  void _showEpisodeSheet() {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 250),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => _EpisodeFullscreenSheet(
        movieTitle: widget.movieTitle ?? '',
        servers: _servers,
        selectedServer: _selectedServer,
        currentServerEps: _currentServerEps,
        flatEps: _flatEps,
        currentEpId: _currentEpId,
        epPerPage: _epPerPage,
        formatEpName: _formatEpName,
        onServerChanged: (idx) {
          setState(() {
            _selectedServer = idx;
            _sheetEpPage = 1;
          });
        },
        onEpisodeSelected: (ep) {
          Navigator.pop(context);
          _switchEpisode(ep, keepPosition: _isLandscape);
        },
      ),
      transitionsBuilder: (_, a, __, child) {
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(
            CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
          ),
          child: child,
        );
      },
    ));
  }

  Widget _buildEpisodeList(ScrollController scrollController, StateSetter setSheetState) {
    final eps = _currentServerEps;
    if (eps.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_creation_outlined, color: Colors.white24, size: 48),
            const SizedBox(height: 12),
            const Text('Phim đang cập nhật tập', style: TextStyle(color: Colors.white54, fontSize: 14)),
            const SizedBox(height: 6),
            const Text('Trailer sẽ được cập nhật khi phim ra mắt', style: TextStyle(color: Colors.white30, fontSize: 12)),
          ],
        ),
      );
    }

    // Deduplicate theo ep_name
    final seen = <String>{};
    final uniqueEps = eps.where((e) {
      final key = (e['ep_name'] ?? e['name'] ?? '').toString();
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();

    final totalPages = uniqueEps.length > _epPerPage ? (uniqueEps.length / _epPerPage).ceil() : 1;
    final currentPage = _sheetEpPage.clamp(1, totalPages);
    final startIdx = (currentPage - 1) * _epPerPage;
    final endIdx = (startIdx + _epPerPage).clamp(0, uniqueEps.length);
    final pagedList = uniqueEps.sublist(startIdx, endIdx);

    return Column(
      children: [
        // Page chips (only if >100 episodes)
        if (totalPages > 1)
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              itemCount: totalPages + 1, // +1 for info chip
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                if (i == totalPages) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Center(
                      child: Text(
                        '${startIdx + 1}-${endIdx}/${uniqueEps.length}',
                        style: const TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                    ),
                  );
                }
                final page = i + 1;
                final isActive = page == currentPage;
                return GestureDetector(
                  onTap: () {
                    setSheetState(() => _sheetEpPage = page);
                    scrollController.jumpTo(0);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: isActive ? AppTheme.accent : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: isActive ? AppTheme.accent : Colors.white24,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        'Trang $page',
                        style: TextStyle(
                          color: isActive ? const Color(0xFF1A1100) : Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        // Grid
        Expanded(
          child: GridView.builder(
            controller: scrollController,
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisExtent: 44,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            itemCount: pagedList.length,
            itemBuilder: (ctx, i) {
              final ep = pagedList[i];
              final epId = ep['id'];
              final rawName = ep['ep_name']?.toString() ?? '';
              final displayName = _formatEpName(rawName);
              final isActive = epId == _currentEpId;

              return GestureDetector(
                onTap: () {
                  Navigator.pop(ctx);
                  _switchEpisode(ep, keepPosition: _isLandscape);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isActive
                        ? AppTheme.accent.withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isActive
                          ? AppTheme.accent.withValues(alpha: 0.5)
                          : Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Row(
                    children: [
                      if (isActive) ...[
                        Container(
                          width: 6, height: 6,
                          decoration: const BoxDecoration(
                            color: AppTheme.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          'Tập $displayName',
                          style: TextStyle(
                            color: isActive ? Colors.white : Colors.white70,
                            fontSize: 13,
                            fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Custom Controls (giống watch room host controls) ──────

  /// Đồng hồ giờ VN — luôn hiện ở góc phải trên video
  /// Tên phim + tập — luôn hiện góc trái trên video
  Widget _buildMovieInfoOverlay() {
    final movieName = widget.movieTitle ?? '';
    final rawEp = _currentEpName;
    if (movieName.isEmpty && rawEp.isEmpty) return const SizedBox.shrink();
    // Bỏ prefix "Tập"/"tap" nếu có trong epName để tránh lặp
    final epClean = rawEp.replaceAll(RegExp(r'^[Tt]ậ?p?\s*', caseSensitive: false), '').trim();
    final title = epClean.isNotEmpty ? '$movieName | Tập $epClean' : movieName;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            'Xiao Phim',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 9,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClockWidget() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 7));
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    final mm = now.month.toString().padLeft(2, '0');
    final yyyy = now.year.toString();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '$h:$m:$s',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          Text(
            '$dd/$mm/$yyyy',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ── Top Bar (landscape fullscreen) ─────────────────
  Widget _buildTopBar() {
    // Format title: "Movie Name | Tập X" (avoid duplicate "Tập" prefix)
    String displayTitle = widget.movieTitle ?? '';
    final epClean = _currentEpName.replaceAll(RegExp(r'^[Tt]ậ?p?\s*', caseSensitive: false), '').trim();
    if (epClean.isNotEmpty && epClean.toLowerCase() != 'full') {
      displayTitle = '$displayTitle | Tập $epClean';
    }

    return Container(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 10, bottom: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            // Left: Back (bright white)
            GestureDetector(
              onTap: () {
                _restoreOrientations();
                Navigator.pop(context);
              },
              child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 16),
            // Lock toggle
            GestureDetector(
              onTap: () {
                setState(() => _isScreenLocked = !_isScreenLocked);
              },
              child: Icon(
                _isScreenLocked ? Icons.lock : Icons.lock_outline,
                color: Colors.white,
                size: 22,
              ),
            ),
            // Center: Title + Episode
            Expanded(
              child: Center(
                child: Text(
                  displayTitle,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            // Right: PiP icon
            if (!_isPiPMode)
              GestureDetector(
                onTap: _enterPiP,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: AppSvgIcon('picture-in-picture-2.svg', size: 22, color: Colors.white),
                ),
              ),
            if (Platform.isIOS)
              GestureDetector(
                onTap: _showAirPlayPicker,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: AppSvgIcon('airplay.svg', size: 22, color: Colors.white),
                ),
              ),
            // Episode list → open episode sheet
            if (_servers.isNotEmpty)
              GestureDetector(
                onTap: _showEpisodeSheet,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: AppSvgIcon('list-video.svg', size: 22, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Center Controls (landscape fullscreen) ──────────
  Widget _buildCenterControls() {
    return Row(
      children: [
        // LEFT zone: double-tap = lùi 10s, long-press = 2x
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              if (_showControls) {
                setState(() => _showControls = false);
                _autoHideControlsTimer?.cancel();
              } else {
                _showControlsWithAutoHide();
              }
            },
            onDoubleTap: () {
              final pos = _currentPos;
              final target = max(0, pos.inSeconds - 10);
              _seekTargetTime = target;
              _lastSeekByUser = DateTime.now().millisecondsSinceEpoch;
              if (mounted) setState(() {
                _currentPos = Duration(seconds: target);
                _isSeeking = true;
              });
              _player?.seek(Duration(seconds: target)).then((_) {
                if (mounted) setState(() {
                  _isSeeking = false;
                  
                });
              });
              _showDoubleTapFeedback(false);
            },
            onLongPressStart: (_) => _onLongPressStart(),
            onLongPressEnd: (_) => _onLongPressEnd(),
            onLongPressCancel: () => _onLongPressEnd(),
            child: const SizedBox.expand(),
          ),
        ),
        // CENTER: Prev | Rewind10 | Play | Forward10 | Next
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Previous episode
              GestureDetector(
                onTap: () {
                  final eps = _currentServerEps;
                  for (int i = 0; i < eps.length; i++) {
                    if (eps[i]['id'] == _currentEpId && i > 0) {
                      _switchEpisode(eps[i - 1], keepPosition: true);
                      break;
                    }
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(Icons.skip_previous_rounded, color: Colors.white.withValues(alpha: 0.5), size: 28),
                ),
              ),
              // Rewind 10s
              GestureDetector(
                onTap: () {
                  final pos = _currentPos;
                  final target = max(0, pos.inSeconds - 10);
                  _seekTargetTime = target;
                  if (mounted) setState(() {
                    _currentPos = Duration(seconds: target);
                    _isSeeking = true;
                  });
                  _player?.seek(Duration(seconds: target)).then((_) {
                    if (mounted) setState(() {
                      _isSeeking = false;
                      
                    });
                  });
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: AppSvgIcon('rewind.svg', size: 30, color: Colors.white),
                ),
              ),
              // Play/Pause (big white circle)
              GestureDetector(
                onTapDown: (_) => setState(() => _playPressed = true),
                onTapUp: (_) => setState(() => _playPressed = false),
                onTapCancel: () => setState(() => _playPressed = false),
                onTap: () {
                  if (_isPlaying) {
                    setState(() => _userPaused = true);
                    _player?.pause();
                  } else {
                    setState(() => _isBuffering = true);
                    _player?.play();
                  }
                },
                child: AnimatedScale(
                  scale: _playPressed ? 0.88 : 1.0,
                  duration: const Duration(milliseconds: 100),
                  child: Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.95),
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 12)],
                    ),
                    child: Icon(
                      _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.black, size: 36,
                    ),
                  ),
                ),
              ),
              // Forward 10s
              GestureDetector(
                onTap: () {
                  final pos = _currentPos;
                  final target = pos.inSeconds + 10;
                  _seekTargetTime = target;
                  if (mounted) setState(() {
                    _currentPos = Duration(seconds: target);
                    _isSeeking = true;
                  });
                  _player?.seek(Duration(seconds: target)).then((_) {
                    if (mounted) setState(() {
                      _isSeeking = false;
                      
                    });
                  });
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: AppSvgIcon('fast-forward.svg', size: 30, color: Colors.white),
                ),
              ),
              // Next episode
              _nextEpisodeButton(),
            ],
          ),
        ),
        // RIGHT zone: double-tap = tới 10s, long-press = 2x
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              if (_showControls) {
                setState(() => _showControls = false);
                _autoHideControlsTimer?.cancel();
              } else {
                _showControlsWithAutoHide();
              }
            },
            onDoubleTap: () {
              final pos = _currentPos;
              final target = pos.inSeconds + 10;
              _seekTargetTime = target;
              _lastSeekByUser = DateTime.now().millisecondsSinceEpoch;
              if (mounted) setState(() {
                _currentPos = Duration(seconds: target);
                _isSeeking = true;
              });
              _player?.seek(Duration(seconds: target)).then((_) {
                if (mounted) setState(() {
                  _isSeeking = false;
                  
                });
              });
              _showDoubleTapFeedback(true);
            },
            onLongPressStart: (_) => _onLongPressStart(),
            onLongPressEnd: (_) => _onLongPressEnd(),
            onLongPressCancel: () => _onLongPressEnd(),
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }

  // ── Bottom Bar (landscape fullscreen) ───────────────
  Widget _buildBottomBar() {
    final progress = _effectiveDur.inSeconds > 0
        ? _currentPos.inSeconds / _effectiveDur.inSeconds
        : 0.0;
    final displayValue = _isDragging ? _dragValue : progress;
    final currentTime = _isDragging
        ? Duration(seconds: (_dragValue * _effectiveDur.inSeconds).toInt())
        : _currentPos;

    return Container(
      padding: const EdgeInsets.only(left: 14, right: 14, bottom: 12, top: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.8)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Timeline: [00:13 ———— slider ———— 1:08:25]
          Row(
            children: [
              Text(
                _formatDuration(currentTime),
                style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.w500),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
                    thumbColor: Colors.white,
                    overlayColor: Colors.white.withValues(alpha: 0.15),
                  ),
                  child: Slider(
                    value: displayValue.clamp(0.0, 1.0),
                    onChangeStart: (value) {
                      _isDragging = true;
                      _dragValue = value;
                      _autoHideControlsTimer?.cancel();
                    },
                    onChanged: (value) {
                      _dragValue = value;
                      setState(() {});
                    },
                    onChangeEnd: (value) {
                      _isDragging = false;
                      _showControlsWithAutoHide();
                      final targetSec = (value * _effectiveDur.inSeconds).toInt();
                      _seekTargetTime = targetSec;
                      _lastSeekByUser = DateTime.now().millisecondsSinceEpoch;
                      if (mounted) setState(() {
                        _currentPos = Duration(seconds: targetSec);
                        _isSeeking = true;
                      });
                      _player?.seek(Duration(seconds: targetSec)).then((_) {
                        if (mounted) setState(() {
                          _isSeeking = false;
                          
                        });
                        Future.delayed(const Duration(milliseconds: 200), () {
                          if (mounted && !_isPlaying) {
                            _player?.play();
                          }
                        });
                      });
                    },
                  ),
                ),
              ),
              Text(
                _formatDuration(_effectiveDur),
                style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.w500),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Toolbar: [Tỷ lệ] [🎤 Server] [💬 Phụ đề]
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Tỷ lệ (aspect ratio)
              _buildToolbarItem(Icons.aspect_ratio_rounded, _aspectRatioLabels[_aspectRatioIndex], _cycleAspectRatio),
              const SizedBox(width: 40),
              // Server (mic icon → server popup)
              _buildToolbarItem(Icons.mic_none_rounded, _servers.isNotEmpty ? (_servers[_selectedServer]['server_name']?.toString() ?? 'Server') : 'Server', _showServerPopup),
              // Phụ đề — hiển thị mọi server (có thể load SRT/ASS)
              const SizedBox(width: 40),
              _buildToolbarItem(Icons.subtitles_rounded, 'Phụ đề', _showSettingsPopup),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToolbarItem(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white.withValues(alpha: 0.8), size: 18),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13)),
        ],
      ),
    );
  }

  // ── Portrait mini controls ──────────────────────────
  Widget _buildPortraitMiniControls() {
    return Container(
      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Timeline
            Row(
              children: [
                Text(_formatDuration(_currentPos), style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace')),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                      activeTrackColor: AppTheme.accent,
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
                      thumbColor: AppTheme.accent,
                    ),
                    child: Slider(
                      value: (_effectiveDur.inSeconds > 0 ? _currentPos.inSeconds / _effectiveDur.inSeconds : 0.0).clamp(0.0, 1.0),
                      onChangeStart: (_) {
                        setState(() => _isSeeking = true);
                      },
                      onChangeEnd: (_) {
                        setState(() => _isSeeking = false);
                      },
                      onChanged: (v) {
                        final t = (v * _effectiveDur.inSeconds).toInt();
                        _player?.seek(Duration(seconds: t));
                        if (mounted) setState(() => _currentPos = Duration(seconds: t));
                      },
                    ),
                  ),
                ),
                Text(_formatDuration(_effectiveDur), style: TextStyle(color: Colors.white38, fontSize: 10, fontFamily: 'monospace')),
              ],
            ),
            // Controls row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Play/Pause
                GestureDetector(
                  onTap: () {
                    if (_isPlaying) {
                      setState(() => _userPaused = true);
                      _player?.pause();
                    } else {
                      setState(() => _isBuffering = true);
                      _player?.play();
                    }
                  },
                  child: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 28),
                ),
                // Rewind 10
                GestureDetector(
                  onTap: () {
                    final pos = _currentPos;
                    final target = max(0, pos.inSeconds - 10);
                    _player?.seek(Duration(seconds: target));
                  },
                  child: const AppSvgIcon('rewind.svg', size: 22, color: Colors.white),
                ),
                // Forward 10
                GestureDetector(
                  onTap: () {
                    final pos = _currentPos;
                    final target = pos.inSeconds + 10;
                    _player?.seek(Duration(seconds: target));
                  },
                  child: const AppSvgIcon('fast-forward.svg', size: 22, color: Colors.white),
                ),
                // PiP icon
                if (!_isPiPMode)
                  GestureDetector(
                    onTap: _enterPiP,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: AppSvgIcon('picture-in-picture-2.svg', size: 20, color: Colors.white),
                    ),
                  ),
                // Subtitle toggle
                if (_subtitles.isNotEmpty)
                  GestureDetector(
                    onTap: () => setState(() => _subtitleEnabled = !_subtitleEnabled),
                    child: Icon(Icons.subtitles_rounded, size: 20, color: _subtitleEnabled ? AppTheme.accent : Colors.white70),
                  ),
                // Fullscreen
                GestureDetector(
                  onTap: _toggleFullscreen,
                  child: const AppSvgIcon('maximize.svg', size: 20, color: Colors.white),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbarItemLegacy(String label, String value, IconData icon, VoidCallback onTap) {
    final progress = _effectiveDur.inSeconds > 0
        ? _currentPos.inSeconds / _effectiveDur.inSeconds
        : 0.0;
    final displayValue = _isDragging ? _dragValue : progress;
    final currentTime = _isDragging
        ? Duration(seconds: (_dragValue * _effectiveDur.inSeconds).toInt())
        : _currentPos;

    return Container(
      padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4, top: 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.9)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Time + Timeline: [00:04 ———— slider ———— 52:42]
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                // Current time
                Text(
                  _formatDuration(currentTime),
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w600),
                ),
                // Slider
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 4,
                      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: AppTheme.accent,
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
                      thumbColor: AppTheme.accent,
                      overlayColor: AppTheme.accent.withValues(alpha: 0.15),
                    ),
                    child: Slider(
                      value: displayValue.clamp(0.0, 1.0),
                      onChangeStart: (value) {
                        _isDragging = true;
                        _dragValue = value;
                        _autoHideControlsTimer?.cancel();
                      },
                      onChanged: (value) {
                        _dragValue = value;
                        setState(() {});
                      },
                      onChangeEnd: (value) {
                        _isDragging = false;
                        _showControlsWithAutoHide();
                        final targetSec = (value * _effectiveDur.inSeconds).toInt();
                        _seekTargetTime = targetSec;
                        _lastSeekByUser = DateTime.now().millisecondsSinceEpoch;
                        // Optimistic update + seeking indicator
                        if (mounted) {
                          setState(() {
                            _currentPos = Duration(seconds: targetSec);
                            _isSeeking = true;
                          });
                        }
                        _player?.seek(Duration(seconds: targetSec)).then((_) {
                          if (mounted) setState(() {
                            _isSeeking = false;
                            
                          });
                          // ★ FIX: Đảm bảo play tiếp sau seek
                          Future.delayed(const Duration(milliseconds: 200), () {
                            if (mounted && !_isPlaying) {
                              _player?.play();
                            }
                          });
                        });
                      },
                    ),
                  ),
                ),
                // Total duration
                Text(
                  _formatDuration(_effectiveDur),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          // Controls row: [Play/Pause] [Rewind] [Forward] [Volume] [Spacer] [PiP] [Mic] [Speed] [Fullscreen]
          Row(
            children: [
              // Play / Pause
              GestureDetector(
                onTap: () {
                  if (_isPlaying) {
                    setState(() => _userPaused = true);
                    _player?.pause();
                  } else {
                    _player?.play();
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: AppSvgIcon(
                    _isPlaying ? 'square.svg' : 'play.svg',
                    size: 22,
                    color: Colors.white,
                  ),
                ),
              ),
              // Rewind 10s
              GestureDetector(
                onTap: () {
                  final pos = _currentPos;
                  final target = max(0, pos.inSeconds - 10);
                  _seekTargetTime = target;
                  if (mounted) setState(() {
                    _currentPos = Duration(seconds: target);
                    _isSeeking = true;
                  });
                  _player?.seek(Duration(seconds: target)).then((_) {
                    if (mounted) setState(() {
                      _isSeeking = false;
                      
                    });
                  });
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: AppSvgIcon('rewind.svg', size: 22, color: Colors.white),
                ),
              ),
              // Forward 10s
              GestureDetector(
                onTap: () {
                  final pos = _currentPos;
                  final target = pos.inSeconds + 10;
                  _seekTargetTime = target;
                  if (mounted) setState(() {
                    _currentPos = Duration(seconds: target);
                    _isSeeking = true;
                  });
                  _player?.seek(Duration(seconds: target)).then((_) {
                    if (mounted) setState(() {
                      _isSeeking = false;
                      
                    });
                  });
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: AppSvgIcon('fast-forward.svg', size: 22, color: Colors.white),
                ),
              ),
              // Volume
              GestureDetector(
                onLongPress: _toggleMute,
                onTap: () => setState(() => _showVolumeInline = !_showVolumeInline),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: AppSvgIcon(
                        _isMuted || _volume == 0
                            ? 'volume-x.svg'
                            : _volume < 50
                                ? 'volume-1.svg'
                                : 'volume-2.svg',
                        size: 20,
                        color: _isMuted || _volume == 0 ? Colors.redAccent : Colors.white,
                      ),
                    ),
                    if (_showVolumeInline)
                      SizedBox(
                        width: 80,
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                            activeTrackColor: AppTheme.accent,
                            inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
                            thumbColor: AppTheme.accent,
                            overlayColor: AppTheme.accent.withValues(alpha: 0.1),
                          ),
                          child: Slider(
                            value: _volume,
                            min: 0,
                            max: 100,
                            divisions: 20,
                            onChanged: (val) {
                              setState(() {
                                _volume = val;
                                _isMuted = val == 0;
                                _player?.setVolume(val);
                              });
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const Spacer(),
              // Subtitle toggle
              if (_subtitles.isNotEmpty)
                GestureDetector(
                  onTap: () => setState(() => _subtitleEnabled = !_subtitleEnabled),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.subtitles_rounded,
                      size: 20,
                      color: _subtitleEnabled ? AppTheme.accent : Colors.white,
                    ),
                  ),
                ),
              // Next episode button
              _nextEpisodeButton(),
              // PiP icon
              if (!_isPiPMode)
                GestureDetector(
                  onTap: _enterPiP,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: AppSvgIcon('picture-in-picture-2.svg', size: 20, color: Colors.white),
                  ),
                ),
              // AirPlay button (iOS only)
              if (Platform.isIOS)
                GestureDetector(
                  onTap: _showAirPlayPicker,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: AppSvgIcon('airplay.svg', size: 20, color: Colors.white),
                  ),
                ),
              // Server (mic icon → server popup)
              if (_servers.isNotEmpty)
                GestureDetector(
                  onTap: _showServerPopup,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: AppSvgIcon(
                      'mic.svg',
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
              // Speed
              GestureDetector(
                onTap: _showSettingsPopup,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: AppSvgIcon(
                    'bolt.svg',
                    size: 20,
                    color: _playbackSpeed != 1.0 ? AppTheme.accent : Colors.white,
                  ),
                ),
              ),
              // Fullscreen
              GestureDetector(
                onTap: _toggleFullscreen,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: AppSvgIcon(
                    _isLandscape ? 'expand.svg' : 'maximize.svg',
                    size: 20,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _cycleSpeed() {
    final idx = _speeds.indexOf(_playbackSpeed);
    final nextIdx = (idx + 1) % _speeds.length;
    setState(() {
      _playbackSpeed = _speeds[nextIdx];
      _player?.setRate(_playbackSpeed);
    });
  }

  void _showSettingsPopup() {
    _settingsPanel = 'main';
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 250),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => _SettingsSlidePanel(
        initialPanel: _settingsPanel,
        subtitleEnabled: _subtitleEnabled,
        subtitles: _subtitles,
        selectedSubtitleColor: _selectedSubtitleColor,
        selectedSubtitleSize: _selectedSubtitleSize,
        selectedSubtitleBgOpacity: _selectedSubtitleBgOpacity,
        selectedQuality: _selectedQuality,
        playbackSpeed: _playbackSpeed,
        onSubtitleEnabledChanged: (val) => setState(() => _subtitleEnabled = val),
        onSubtitleColorChanged: (val) => setState(() => _selectedSubtitleColor = val),
        onSubtitleSizeChanged: (val) => setState(() => _selectedSubtitleSize = val),
        onSubtitleBgOpacityChanged: (val) => setState(() => _selectedSubtitleBgOpacity = val),
        onQualityChanged: (val) => setState(() => _selectedQuality = val),
        onSpeedChanged: (val) => setState(() => _playbackSpeed = val),
      ),
      transitionsBuilder: (_, a, __, child) {
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(
            CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
          ),
          child: child,
        );
      },
    ));
  }

  List<Widget> _buildMainPanel(Function setModalState) {
    return [
      _buildSettingsRow('Chất lượng', _selectedQuality, Icons.chevron_right, () {
        setModalState(() => _settingsPanel = 'quality');
      }),
      _buildSettingsRow('Phụ đề', 'Tuỳ chỉnh', Icons.chevron_right, () {
        setModalState(() => _settingsPanel = 'subtitles');
      }),
      _buildSettingsRow('Tốc độ', '${_playbackSpeed}x', Icons.chevron_right, () {
        setModalState(() => _settingsPanel = 'speed');
      }),
    ];
  }

  List<Widget> _buildQualityPanel(Function setModalState) {
    final qualities = ['Auto', '1080p', '720p', '480p', '360p'];
    return qualities.map((q) => _buildOptionRow(q, _selectedQuality == q, () {
      setModalState(() {
        _selectedQuality = q;
        _settingsPanel = 'main';
      });
    })).toList();
  }

  List<Widget> _buildSubtitlesPanel(Function setModalState) {
    final colors = [
      {'label': 'Trắng', 'hex': '#FFFFFF'},
      {'label': 'Vàng', 'hex': '#FFFF00'},
      {'label': 'Xanh', 'hex': '#00FFFF'},
    ];
    final sizes = [
      {'label': '14px', 'value': 14.0},
      {'label': '16px', 'value': 16.0},
      {'label': '18px', 'value': 18.0},
      {'label': '20px', 'value': 20.0},
    ];
    return [
      // Toggle on/off
      ListTile(
        title: const Text('Hiện phụ đề', style: TextStyle(color: Colors.white, fontSize: 16)),
        trailing: Switch(
          value: _subtitleEnabled,
          activeColor: AppTheme.accent,
          onChanged: (val) => setModalState(() => _subtitleEnabled = val),
        ),
      ),
      if (_subtitles.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('Phim này chưa có phụ đề SRT', style: TextStyle(color: Colors.white38, fontSize: 13)),
        ),
      const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Màu chữ', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
      ),
      ...colors.map((c) => _buildColorRow(c['label']!, c['hex']!, _selectedSubtitleColor == c['hex'], () {
        setModalState(() => _selectedSubtitleColor = c['hex']!);
      })),
      const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Cỡ chữ', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
      ),
      ...sizes.map((s) => _buildOptionRow(s['label']! as String, _selectedSubtitleSize == s['value'], () {
        setModalState(() => _selectedSubtitleSize = s['value'] as double);
      })),
      const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Nền phụ đề', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
      ),
      _buildOptionRow('Tắt', _selectedSubtitleBgOpacity == 0.0, () {
        setModalState(() => _selectedSubtitleBgOpacity = 0.0);
      }),
      _buildOptionRow('Mờ nhẹ', _selectedSubtitleBgOpacity == 0.3, () {
        setModalState(() => _selectedSubtitleBgOpacity = 0.3);
      }),
      _buildOptionRow('Đậm', _selectedSubtitleBgOpacity == 0.6, () {
        setModalState(() => _selectedSubtitleBgOpacity = 0.6);
      }),
      _buildOptionRow('Đặc', _selectedSubtitleBgOpacity == 0.85, () {
        setModalState(() => _selectedSubtitleBgOpacity = 0.85);
      }),
    ];
  }

  List<Widget> _buildSpeedPanel(Function setModalState) {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
    return speeds.map((s) => _buildOptionRow('${s}x', _playbackSpeed == s, () {
      setState(() {
        _playbackSpeed = s;
        _player?.setRate(s);
      });
      setModalState(() => _settingsPanel = 'main');
    })).toList();
  }

  Widget _buildSettingsRow(String label, String value, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16))),
            Text(value, style: const TextStyle(color: Colors.white70, fontSize: 14)),
            Icon(icon, color: Colors.white70, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionRow(String label, bool isActive, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isActive ? const Color(0xFF2A2D35) : Colors.transparent,
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16))),
            if (isActive) const Icon(Icons.check, color: AppTheme.accent, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildColorRow(String label, String hex, bool isActive, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isActive ? const Color(0xFF2A2D35) : Colors.transparent,
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: Color(int.parse('0xFF${hex.substring(1)}')),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24, width: 1),
              ),
            ),
            Expanded(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16))),
            if (isActive) const Icon(Icons.check, color: AppTheme.accent, size: 20),
          ],
        ),
      ),
    );
  }

  void _toggleMute() {
    final currentVol = _volume;
    if (currentVol > 0) {
      _isMuted = true;

      _player?.setVolume(0.0);
    } else {
      _isMuted = false;
      final vol = _volume > 0 ? _volume : 100.0;

      _player?.setVolume(vol);
    }
    setState(() {});
  }

  void _toggleFullscreen() {
    if (_isLandscape) {
      _restoreOrientations();
      Future.delayed(const Duration(milliseconds: 300), () {
        _restoreOrientations();
      });
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _showServerPopup() {
    if (_servers.isEmpty) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF1E2026),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 16),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Title
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text(
                    'Chọn server',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            // Divider
            Container(
              height: 1,
              color: Colors.white.withValues(alpha: 0.1),
            ),
            // Server list
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _servers.length,
                itemBuilder: (context, i) {
                   final serverName =
                       _servers[i]['server_name']?.toString() ??
                           'Server ${i + 1}';
                   final isActive = i == _selectedServer;
                   final rawEps = (_servers[i]['episodes'] as List<dynamic>?) ?? [];
                   final dedupedNames = <String>{};
                   for (final e in rawEps) {
                     dedupedNames.add((e['ep_name'] ?? e['name'] ?? '').toString());
                   }

                   return InkWell(
                     onTap: () {
                       if (i != _selectedServer) {
                         _switchServer(i);
                       }
                       Navigator.pop(context);
                     },
                     child: Container(
                       padding: const EdgeInsets.symmetric(
                         horizontal: 16,
                         vertical: 14,
                       ),
                       decoration: BoxDecoration(
                         color: isActive
                             ? AppTheme.accent.withValues(alpha: 0.15)
                             : Colors.transparent,
                       ),
                       child: Row(
                         children: [
                           Expanded(
                             child: Text(
                               '$serverName • ${dedupedNames.length} tập',
                              style: TextStyle(
                                color: isActive
                                    ? AppTheme.accent
                                    : Colors.white,
                                fontSize: 16,
                                fontWeight: isActive
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (isActive)
                            Icon(
                              Icons.check_circle,
                              color: AppTheme.accent,
                              size: 24,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            // Bottom padding for safe area
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  void _showVolumeSlider() {
    // Unused — inline volume slider is used instead
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _retry() {
    setState(() { _error = null; _isLoading = true; _playerReady = false; });
    if (_playerMode == _PlayerMode.hls && _player != null) {
      final retryUrl = kIsWeb ? AppConfig.proxyHlsUrl(_currentUrl) : _currentUrl;
      _initPlayer(retryUrl);
    } else if (_currentUrl.isNotEmpty) {
      _webController?.loadUrl(urlRequest: URLRequest(url: WebUri(_currentUrl)));
    }
  }

  // ── Server selector — tất cả nguồn đều sống ──────────
  Widget _buildServerSelector() {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        itemCount: _servers.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final s = _servers[i];
          final isActive = i == _selectedServer;
          final rawEps = (s['episodes'] as List<dynamic>?) ?? [];
          final dedupedNames = <String>{};
          for (final e in rawEps) {
            dedupedNames.add((e['ep_name'] ?? e['name'] ?? '').toString());
          }

          return GestureDetector(
            onTap: () {
              setState(() => _selectedServer = i);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: isActive ? Colors.white.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.02),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isActive ? Colors.white.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.1),
                ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 6, height: 6,
                  decoration: const BoxDecoration(color: Color(0xFF4CAF50), shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  s['server_name']?.toString() ?? 'Server ${i + 1}',
                  style: TextStyle(
                    color: isActive ? Colors.white.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${dedupedNames.length} tập',
                  style: TextStyle(
                    color: isActive ? Colors.white.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.3),
                    fontSize: 10,
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  // ── Episode grid ──────────────────────────────────
  Widget _buildEpisodeGrid() {
    final allEps = _currentServerEps;
    if (allEps.isEmpty && _flatEps.isEmpty) {
      return const Center(
        child: Text('Đang tải tập phim...', style: TextStyle(color: Colors.white38, fontSize: 13)),
      );
    }

    final list = allEps.isNotEmpty ? allEps : _flatEps;

    // Deduplicate theo ep_name
    final seen = <String>{};
    final uniqueList = list.where((e) {
      final key = (e['ep_name'] ?? e['name'] ?? '').toString();
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();

    final totalPages = uniqueList.length > _epPerPage ? (uniqueList.length / _epPerPage).ceil() : 1;
    final currentPage = _epPage.clamp(1, totalPages);
    final startIdx = (currentPage - 1) * _epPerPage;
    final endIdx = (startIdx + _epPerPage).clamp(0, uniqueList.length);
    final pagedList = uniqueList.sublist(startIdx, endIdx);

    return Column(
      children: [
        // Page chips (only if >100 episodes)
        if (totalPages > 1)
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              itemCount: totalPages + 1, // +1 for info chip
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                if (i == totalPages) {
                  // Info chip: "1-100/250"
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Center(
                      child: Text(
                        '${startIdx + 1}-${endIdx}/${uniqueList.length}',
                        style: const TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                    ),
                  );
                }
                final page = i + 1;
                final isActive = page == currentPage;
                return GestureDetector(
                  onTap: () => setState(() => _epPage = page),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: isActive ? AppTheme.accent : Colors.transparent,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: isActive ? AppTheme.accent : Colors.white24,
                        width: 1,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        'Trang $page',
                        style: TextStyle(
                          color: isActive ? const Color(0xFF1A1100) : Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        // Grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: Responsive.episodeColumns(context),
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
              childAspectRatio: 2.2,
            ),
            itemCount: pagedList.length,
            itemBuilder: (context, i) {
              final ep = pagedList[i];
              final epId = ep['id'];
              final isActive = epId == _currentEpId ||
                  (epId == null && i == 0 && _currentEpId == widget.episodeId);
              final label = (ep['ep_name'] ?? ep['name'] ?? '${startIdx + i + 1}').toString();

              return GestureDetector(
                onTap: () => _switchEpisode(ep),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    gradient: isActive ? const LinearGradient(colors: [Color(0xFFFECF59), Color(0xFFF1E2B0)], begin: Alignment.centerLeft, end: Alignment.centerRight) : null,
                    color: isActive ? null : const Color(0xFF1E2130),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isActive ? const Color(0xFFFECF59) : const Color(0x22FFFFFF),
                    ),
                  ),
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: isActive ? const Color(0xFF1A1100) : Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 80), // Spacer cho BottomNav
      ],
    );
  }
}

// ── Fullscreen Episode Sheet Widget ──────────────────────────

class _EpisodeFullscreenSheet extends StatefulWidget {
  final String movieTitle;
  final List<dynamic> servers;
  final int selectedServer;
  final List<dynamic> currentServerEps;
  final List<dynamic> flatEps;
  final dynamic currentEpId;
  final int epPerPage;
  final String Function(String) formatEpName;
  final ValueChanged<int> onServerChanged;
  final ValueChanged<dynamic> onEpisodeSelected;

  const _EpisodeFullscreenSheet({
    required this.movieTitle,
    required this.servers,
    required this.selectedServer,
    required this.currentServerEps,
    required this.flatEps,
    required this.currentEpId,
    required this.epPerPage,
    required this.formatEpName,
    required this.onServerChanged,
    required this.onEpisodeSelected,
  });

  @override
  State<_EpisodeFullscreenSheet> createState() => _EpisodeFullscreenSheetState();
}

class _EpisodeFullscreenSheetState extends State<_EpisodeFullscreenSheet> {
  late int _selectedServer;
  int _epPage = 1;

  @override
  void initState() {
    super.initState();
    _selectedServer = widget.selectedServer;
  }

  /// Lấy episodes trực tiếp từ server đang chọn, không phụ thuộc widget.currentServerEps
  List<dynamic> get _eps {
    if (widget.servers.isNotEmpty && _selectedServer < widget.servers.length) {
      final eps = (widget.servers[_selectedServer]['episodes'] as List<dynamic>?) ?? [];
      if (eps.isNotEmpty) return eps;
    }
    return widget.flatEps;
  }

  /// Tìm ep_id tương ứng trên server mới để highlight (so sánh theo ep_slug hoặc index)
  dynamic _findMatchingEpId(List<dynamic> newEps, dynamic oldEpId) {
    if (oldEpId == null || widget.currentServerEps.isEmpty) return null;
    final oldEp = widget.currentServerEps.where((e) => e['id'] == oldEpId).toList();
    if (oldEp.isEmpty) return null;
    final oldSlug = (oldEp.first['ep_slug'] ?? '').toString();
    final oldIdx = widget.currentServerEps.indexOf(oldEp.first);
    // Tìm theo slug trước
    if (oldSlug.isNotEmpty) {
      final bySlug = newEps.where((e) => (e['ep_slug'] ?? '').toString() == oldSlug).toList();
      if (bySlug.isNotEmpty) return bySlug.first['id'];
    }
    // Fallback: tìm theo index
    if (oldIdx < newEps.length) return newEps[oldIdx]['id'];
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final seen = <String>{};
    final uniqueEps = _eps.where((e) {
      final key = (e['ep_name'] ?? e['name'] ?? '').toString();
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();

    final totalPages = uniqueEps.length > widget.epPerPage ? (uniqueEps.length / widget.epPerPage).ceil() : 1;
    final currentPage = _epPage.clamp(1, totalPages);
    final startIdx = (currentPage - 1) * widget.epPerPage;
    final endIdx = (startIdx + widget.epPerPage).clamp(0, uniqueEps.length);
    final pagedList = uniqueEps.sublist(startIdx, endIdx);

    // Tìm ep_id để highlight trên server hiện tại
    final highlightEpId = _findMatchingEpId(uniqueEps, widget.currentEpId);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.pop(context),
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: Colors.transparent,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () {},
              child: Container(
                height: MediaQuery.of(context).size.height,
                decoration: const BoxDecoration(color: Color(0xFF1A1C21)),
                child: Column(
                  children: [
                    // Safe area
                    SizedBox(height: MediaQuery.of(context).padding.top + 16),
                    // Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 20, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Danh sách tập', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                                const SizedBox(height: 4),
                                Text(widget.movieTitle, style: const TextStyle(color: Colors.white38, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                          GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), shape: BoxShape.circle),
                              child: const Icon(Icons.close, color: Colors.white60, size: 20),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Episode count
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 14, 20, 0),
                      child: Row(
                        children: [
                          const Icon(Icons.menu_rounded, color: Colors.white, size: 18),
                          const SizedBox(width: 8),
                          Text('${uniqueEps.length} tập', style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                    // Server tabs
                    if (widget.servers.length > 1)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: widget.servers.asMap().entries.map((entry) {
                              final idx = entry.key;
                              final server = entry.value;
                              final serverName = server['server_name']?.toString() ?? 'Server ${idx + 1}';
                              final isActive = idx == _selectedServer;
                              final serverEps = (server['episodes'] as List<dynamic>?) ?? [];
                              final serverEpCount = <String>{};
                              for (final e in serverEps) {
                                serverEpCount.add((e['ep_name'] ?? e['name'] ?? '').toString());
                              }

                              return GestureDetector(
                                onTap: () {
                                  setState(() { _selectedServer = idx; _epPage = 1; });
                                  widget.onServerChanged(idx);
                                },
                                child: Container(
                                  margin: const EdgeInsets.only(right: 8),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: isActive ? Colors.white.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.02),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: isActive ? Colors.white.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.1)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 6, height: 6,
                                        decoration: const BoxDecoration(color: Color(0xFF4CAF50), shape: BoxShape.circle),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(serverName, style: TextStyle(color: isActive ? Colors.white.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.5), fontSize: 12, fontWeight: FontWeight.w600)),
                                      const SizedBox(width: 4),
                                      Text('${serverEpCount.length} tập', style: TextStyle(color: isActive ? Colors.white.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.3), fontSize: 10)),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(24, 14, 24, 0),
                      child: Divider(color: Colors.white12, height: 1),
                    ),
                    // Page chips
                    if (totalPages > 1)
                      SizedBox(
                        height: 36,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                          itemCount: totalPages,
                          separatorBuilder: (_, __) => const SizedBox(width: 6),
                          itemBuilder: (context, i) {
                            final page = i + 1;
                            final isActive = page == currentPage;
                            return GestureDetector(
                              onTap: () => setState(() => _epPage = page),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isActive ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: isActive ? Colors.white.withValues(alpha: 0.3) : Colors.white24),
                                ),
                                child: Center(child: Text('Trang $page', style: TextStyle(color: isActive ? Colors.white : Colors.white54, fontSize: 11, fontWeight: FontWeight.w600))),
                              ),
                            );
                          },
                        ),
                      ),
                    // Episodes grid — compressed with margins
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.fromLTRB(72, 10, 72, 24),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                          childAspectRatio: 7.0,
                        ),
                        itemCount: pagedList.length,
                        itemBuilder: (ctx, i) {
                          final ep = pagedList[i];
                          final epId = ep['id'];
                          final rawName = ep['ep_name']?.toString() ?? '';
                          final displayName = widget.formatEpName(rawName);
                          final isActive = epId == highlightEpId;
                          final label = 'Tập $displayName';

                          return GestureDetector(
                            onTap: () => widget.onEpisodeSelected(ep),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              decoration: BoxDecoration(
                                gradient: isActive ? const LinearGradient(colors: [Color(0xFFFECF59), Color(0xFFF1E2B0)], begin: Alignment.centerLeft, end: Alignment.centerRight) : null,
                                color: isActive ? null : const Color(0xFF1E2130),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: isActive ? const Color(0xFFFECF59) : const Color(0x22FFFFFF), width: 1),
                              ),
                              child: Center(
                                child: Text(label, style: TextStyle(color: isActive ? const Color(0xFF1A1100) : Colors.white54, fontSize: 13, fontWeight: isActive ? FontWeight.w600 : FontWeight.w500), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Settings Slide Panel (from right) ──────────────────────

class _SettingsSlidePanel extends StatefulWidget {
  final String initialPanel;
  final bool subtitleEnabled;
  final List<dynamic> subtitles;
  final String selectedSubtitleColor;
  final double selectedSubtitleSize;
  final double selectedSubtitleBgOpacity;
  final String selectedQuality;
  final double playbackSpeed;
  final ValueChanged<bool> onSubtitleEnabledChanged;
  final ValueChanged<String> onSubtitleColorChanged;
  final ValueChanged<double> onSubtitleSizeChanged;
  final ValueChanged<double> onSubtitleBgOpacityChanged;
  final ValueChanged<String> onQualityChanged;
  final ValueChanged<double> onSpeedChanged;

  const _SettingsSlidePanel({
    required this.initialPanel,
    required this.subtitleEnabled,
    required this.subtitles,
    required this.selectedSubtitleColor,
    required this.selectedSubtitleSize,
    required this.selectedSubtitleBgOpacity,
    required this.selectedQuality,
    required this.playbackSpeed,
    required this.onSubtitleEnabledChanged,
    required this.onSubtitleColorChanged,
    required this.onSubtitleSizeChanged,
    required this.onSubtitleBgOpacityChanged,
    required this.onQualityChanged,
    required this.onSpeedChanged,
  });

  @override
  State<_SettingsSlidePanel> createState() => _SettingsSlidePanelState();
}

class _SettingsSlidePanelState extends State<_SettingsSlidePanel> {
  late String _currentPanel;
  late bool _subtitleEnabled;
  late String _selectedSubtitleColor;
  late double _selectedSubtitleSize;
  late double _selectedSubtitleBgOpacity;
  late String _selectedQuality;
  late double _playbackSpeed;

  @override
  void initState() {
    super.initState();
    _currentPanel = widget.initialPanel;
    _subtitleEnabled = widget.subtitleEnabled;
    _selectedSubtitleColor = widget.selectedSubtitleColor;
    _selectedSubtitleSize = widget.selectedSubtitleSize;
    _selectedSubtitleBgOpacity = widget.selectedSubtitleBgOpacity;
    _selectedQuality = widget.selectedQuality;
    _playbackSpeed = widget.playbackSpeed;
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: const Color(0xFF1E2026),
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, fontSize: 14, decoration: TextDecoration.none),
          child: SizedBox(
            width: MediaQuery.of(context).size.width * 0.45,
            height: MediaQuery.of(context).size.height,
            child: Column(
              children: [
                // Header
                Padding(
                  padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 16, left: 16, right: 16, bottom: 8),
                  child: Row(
                    children: [
                      if (_currentPanel != 'main')
                        GestureDetector(
                          onTap: () => setState(() => _currentPanel = 'main'),
                          child: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 20),
                        ),
                      if (_currentPanel != 'main') const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _currentPanel == 'main' ? 'Cài đặt' :
                          _currentPanel == 'quality' ? 'Chất lượng' :
                          _currentPanel == 'subtitles' ? 'Phụ đề' : 'Tốc độ',
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600, decoration: TextDecoration.none),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), shape: BoxShape.circle),
                          child: const Icon(Icons.close, color: Colors.white60, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                // Content
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: _currentPanel == 'main'
                        ? _buildMainPanel()
                        : _currentPanel == 'quality'
                            ? _buildQualityPanel()
                            : _currentPanel == 'subtitles'
                                ? _buildSubtitlesPanel()
                                : _buildSpeedPanel(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildMainPanel() {
    return [
      _sectionCard(
        child: Column(
          children: [
            _mainRow('Chất lượng', _selectedQuality, () {
              setState(() => _currentPanel = 'quality');
            }),
            const Divider(color: Colors.white12, height: 1),
            _mainRow('Phụ đề', 'Tuỳ chỉnh', () {
              setState(() => _currentPanel = 'subtitles');
            }),
            const Divider(color: Colors.white12, height: 1),
            _mainRow('Tốc độ', '${_playbackSpeed}x', () {
              setState(() => _currentPanel = 'speed');
            }),
          ],
        ),
      ),
    ];
  }

  Widget _mainRow(String title, String value, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Expanded(child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 15, decoration: TextDecoration.none))),
            Text(value, style: TextStyle(color: Colors.white38, fontSize: 13, decoration: TextDecoration.none)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildQualityPanel() {
    final qualities = ['Auto', '1080p', '720p', '480p', '360p'];
    return [
      _sectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Chọn chất lượng', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
            const SizedBox(height: 10),
            Row(
              children: qualities.map((q) {
                final isActive = _selectedQuality == q;
                return Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedQuality = q;
                        _currentPanel = 'main';
                      });
                      widget.onQualityChanged(q);
                    },
                    child: Container(
                      margin: const EdgeInsets.only(right: 6),
                      height: 40,
                      decoration: BoxDecoration(
                        color: isActive ? AppTheme.accent : const Color(0xFF2A2D36),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(q, style: TextStyle(color: isActive ? const Color(0xFF1A1100) : Colors.white54, fontSize: 12, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _buildSubtitlesPanel() {
    final colors = <Map<String, dynamic>>[
      {'label': 'Trắng', 'hex': '#FFFFFF', 'color': Colors.white},
      {'label': 'Vàng', 'hex': '#FFFF00', 'color': Colors.yellow},
      {'label': 'Xanh', 'hex': '#00FFFF', 'color': Colors.cyan},
    ];
    final sizes = [14.0, 16.0, 18.0, 20.0];
    final bgOptions = <Map<String, dynamic>>[
      {'label': 'Tắt', 'value': 0.0},
      {'label': 'Mờ', 'value': 0.3},
      {'label': 'Đậm', 'value': 0.6},
      {'label': 'Đặc', 'value': 0.85},
    ];

    return [
      // Toggle card
      _sectionCard(
        child: Row(
          children: [
            const Expanded(
              child: Text('Hiện phụ đề', style: TextStyle(color: Colors.white, fontSize: 15, decoration: TextDecoration.none)),
            ),
            Switch(
              value: _subtitleEnabled,
              activeColor: AppTheme.accent,
              onChanged: (val) {
                setState(() => _subtitleEnabled = val);
                widget.onSubtitleEnabledChanged(val);
              },
            ),
          ],
        ),
      ),
      if (widget.subtitles.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Text('Phim này chưa có phụ đề SRT', style: TextStyle(color: Colors.white30, fontSize: 12, decoration: TextDecoration.none)),
        ),
      const SizedBox(height: 8),
      // Color section
      _sectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Màu phụ đề', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
            const SizedBox(height: 10),
            Row(
              children: colors.map((c) {
                final hex = c['hex'] as String;
                final isActive = _selectedSubtitleColor == hex;
                return GestureDetector(
                  onTap: () {
                    setState(() => _selectedSubtitleColor = hex);
                    widget.onSubtitleColorChanged(hex);
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 10),
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: isActive ? AppTheme.accent.withValues(alpha: 0.2) : const Color(0xFF2A2D36),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isActive ? AppTheme.accent : Colors.white.withValues(alpha: 0.08),
                        width: isActive ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 16, height: 16,
                          decoration: BoxDecoration(color: c['color'] as Color, shape: BoxShape.circle, border: Border.all(color: Colors.white24, width: 1)),
                        ),
                        const SizedBox(height: 2),
                        Text(c['label'] as String, style: TextStyle(color: isActive ? Colors.white : Colors.white38, fontSize: 8, decoration: TextDecoration.none)),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      // Size section
      _sectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cỡ chữ', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
            const SizedBox(height: 10),
            Row(
              children: sizes.map((s) {
                final isActive = _selectedSubtitleSize == s;
                return Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _selectedSubtitleSize = s);
                      widget.onSubtitleSizeChanged(s);
                    },
                    child: Container(
                      margin: const EdgeInsets.only(right: 6),
                      height: 36,
                      decoration: BoxDecoration(
                        color: isActive ? AppTheme.accent : const Color(0xFF2A2D36),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text('${s.toInt()}', style: TextStyle(color: isActive ? const Color(0xFF1A1100) : Colors.white54, fontSize: 13, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      // Background section
      _sectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Nền phụ đề', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
            const SizedBox(height: 10),
            Row(
              children: bgOptions.map((bg) {
                final isActive = _selectedSubtitleBgOpacity == (bg['value'] as double);
                return Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _selectedSubtitleBgOpacity = bg['value'] as double);
                      widget.onSubtitleBgOpacityChanged(bg['value'] as double);
                    },
                    child: Container(
                      margin: const EdgeInsets.only(right: 6),
                      height: 36,
                      decoration: BoxDecoration(
                        color: isActive ? AppTheme.accent : const Color(0xFF2A2D36),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(bg['label'] as String, style: TextStyle(color: isActive ? const Color(0xFF1A1100) : Colors.white54, fontSize: 12, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _sectionCard({required Widget child}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF252830),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  List<Widget> _buildSpeedPanel() {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    return [
      _sectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Chọn tốc độ', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: speeds.map((s) {
                final isActive = _playbackSpeed == s;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _playbackSpeed = s;
                      _currentPanel = 'main';
                    });
                    widget.onSpeedChanged(s);
                  },
                  child: Container(
                    width: 56,
                    height: 36,
                    decoration: BoxDecoration(
                      color: isActive ? AppTheme.accent : const Color(0xFF2A2D36),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text('${s}x', style: TextStyle(color: isActive ? const Color(0xFF1A1100) : Colors.white54, fontSize: 13, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _buildSettingsRow(String title, String value, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, decoration: TextDecoration.none))),
            Text(value, style: const TextStyle(color: Colors.white54, fontSize: 14, decoration: TextDecoration.none)),
            const SizedBox(width: 4),
            Icon(icon, color: Colors.white54, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionRow(String label, bool isActive, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isActive ? AppTheme.accent.withValues(alpha: 0.15) : Colors.transparent,
        child: Row(
          children: [
            if (isActive)
              Icon(Icons.check, color: AppTheme.accent, size: 18),
            if (isActive) const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: isActive ? AppTheme.accent : Colors.white,
                fontSize: 15,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }
}