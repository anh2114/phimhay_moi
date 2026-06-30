import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:dio/dio.dart';
import 'package:media_kit/media_kit.dart' show Player, Media;
import 'package:media_kit_video/media_kit_video.dart' show Video, VideoController, NoVideoControls;
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
import 'package:phimhay_app/services/smartlink_service.dart';
import 'package:phimhay_app/widgets/smartlink_banner_widget.dart';
import 'package:phimhay_app/services/m3u8_ad_parser.dart';
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

  static void _restoreOrientations() {
    if (_isTablet) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
  }
  final Dio _dio = Dio();
  final MovieService _movieService = MovieService();
  InAppWebViewController? _webController;
  Player? _hlsPlayer;
  VideoController? _videoController;
  static const _pipChannel = MethodChannel('phimhay/pip');
  static const _airplayChannel = MethodChannel('phimhay/airplay');
  bool _pipAvailable = false;

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
  bool _hasSwitchedEp = false; // Da chuyen tap → khong restore progress cu

  // Controls overlay
  bool _showControls = true;
  bool _showSkipIntro = false;
  StreamSubscription<Duration>? _positionSub;
  bool _playerReady = false; // true khi media đã load xong
  StreamSubscription<bool>? _playingSub;

  // Custom player controls (giống watch room host controls)
  bool _isPlaying = false;
  double _playbackSpeed = 1.0;
  static const List<double> _speeds = [0.5, 1.0, 1.5, 2.0, 3.0];
  String _settingsPanel = 'main'; // 'main', 'quality', 'subtitles', 'speed'
  String _selectedQuality = 'Auto';
  String _selectedSubtitleColor = '#FFFFFF';
  double _selectedSubtitleSize = 14.0;
  double _volume = 100.0;
  bool _isMuted = false;
  bool _isDragging = false;
  bool _showVolumeInline = false;
  double _dragValue = 0;
  int _lastPositionUpdate = 0;
  Duration _currentPos = Duration.zero;
  Duration _currentDur = Duration.zero;

  // Đồng hồ hiện thị giờ VN (luôn hiện, không ẩn theo tap)
  Timer? _clockTimer;

  // Watch progress tracking
  Timer? _saveProgressTimer;
  int _currentPosition = 0;
  int _currentDuration = 0;
  Map<String, dynamic>? _savedProgress;

  // ★ Fix: stuck detector + state sync
  Timer? _stuckDetector;
  Timer? _stateSyncTimer;
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
    WakelockPlus.enable(); // Chặn màn hình khóa khi xem phim
    _lockBrightness(); // Giữ độ sáng max khi xem phim
    _checkPipAvailability();
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

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    if (widget.initialPosition > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isLandscape) _toggleFullscreen();
      });
    }
  }

  // ── Fetch ad markers từ API ────────────────────────
  Future<void> _fetchAdMarkers(String m3u8Url, String serverName) async {
    if (widget.movieId <= 0 || m3u8Url.isEmpty) return;
    try {
      final res = await _dio.get('${AppConfig.apiUrl}/ad_markers.php', queryParameters: {
        'url': m3u8Url,
        'movie_id': widget.movieId,
        'server_name': serverName,
      });
      final data = res.data;
      if (data is Map && data['success'] == true) {
        final ads = data['ads'] as List<dynamic>? ?? [];
        _adMarkers = ads.map((e) => Map<String, dynamic>.from(e)).toList();
        if (_adMarkers.isNotEmpty) {
          debugPrint('Ad markers: ${_adMarkers.length} zones');
        }
      }
    } catch (_) {}
  }

  // ── Parse m3u8 để detect ad chính xác ──────────────────
  Future<void> _parseM3u8ForAds(String m3u8Url) async {
    try {
      _m3u8Result = await _adParser.parse(m3u8Url);
      if (_m3u8Result!.hasAds) {
        debugPrint('=== M3U8 AD PARSER ===');
        debugPrint('Segments: ${_m3u8Result!.segments.length}');
        debugPrint('Ad zones: ${_m3u8Result!.adZones.length}');
        for (final zone in _m3u8Result!.adZones) {
          debugPrint('  $zone');
        }
        debugPrint('======================');
      }
    } catch (e) {
      debugPrint('M3U8 parse error: $e');
    }
  }

  // ── Load subtitles for current episode ──────────────────
  Future<void> _loadSubtitles(Map<String, dynamic> episode) async {
    // Try API field first
    final subUrl = (episode['link_sub'] ?? episode['subtitle_url'] ?? '').toString().trim();
    final urlsToTry = <String>[];
    if (subUrl.isNotEmpty) urlsToTry.add(subUrl);

    // Convention URL: /art/{slug}/{slug}_vi.srt
    final slug = widget.movieSlug ?? '';
    if (slug.isNotEmpty) {
      urlsToTry.add('${AppConfig.baseUrl}/art/$slug/${slug}_vi.srt');
    }

    if (urlsToTry.isEmpty) {
      setState(() { _subtitles = []; _subtitleEnabled = false; });
      return;
    }

    for (final url in urlsToTry) {
      try {
        final subs = await _srtParser.fetchAndParse(url);
        if (mounted && subs.isNotEmpty) {
          _currentSubtitleUrl = url;
          setState(() { _subtitles = subs; _subtitleEnabled = true; });
          return;
        }
      } catch (_) {}
    }
    // No subtitles found
    setState(() { _subtitles = []; _subtitleEnabled = false; });
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

  // ── Check và skip ad zone ────────────────────────
  int _lastAdCheckTime = 0; // Throttle periodic check

  void _checkAdZone(int positionSec) {
    if (_adSkipping || _currentUrl.isEmpty) return;

    // ★ 0. Neu user vua seek → reset jump tracker (khong unmute sai)
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSeekByUser < 2000) {
      _lastPositionForJump = positionSec;
      return; // Bo qua check sau seek
    }

    // ★ 1. Check parsed m3u8 ad zones
    if (_m3u8Result != null && _m3u8Result!.hasAds) {
      final adZone = _m3u8Result!.adZoneAt(positionSec.toDouble());
      if (adZone != null && !_adMuted) {
        debugPrint('M3U8 AD HIT at ${positionSec}s → mute');
        _muteForAdSkip();
        return;
      }
      final nextAd = _m3u8Result!.nextAdAfter(positionSec.toDouble());
      if (nextAd != null && nextAd.startTime - positionSec <= 3 && !_adMuted) {
        debugPrint('AD LOOK-AHEAD: mute at ${positionSec}s');
        _muteForAdSkip();
        return;
      }
    }

    // ★ 2. Detect position jump
    if (_lastPositionForJump >= 0) {
      final jump = positionSec - _lastPositionForJump;

      // Jump nguoc RẤT LỚN (>30s) → server dang phat ad (position reset ve 0)
      // → SKIP NGAY: stop → open → seek den sau ad
      if (jump < -30 && !_adSkipping) {
        int lastPos = _lastPositionForJump;
        int seekTarget = lastPos + 10; // fallback

        // Tim ad marker gan nhat SAU position cu
        int bestStart = 99999;
        for (final ad in _adMarkers) {
          final start = (ad['start_time'] as int?) ?? 0;
          // Ad marker nam SAU position cu, trong vong 60s
          if (start > lastPos && (start - lastPos) < 60) {
            if (start < bestStart) bestStart = start;
          }
        }
        if (bestStart < 99999) {
          seekTarget = bestStart + 2;
        }

        debugPrint('AD SKIP: ${lastPos}s → ${positionSec}s → seek to ${seekTarget}s');
        _skipAdZone(seekTarget);
      }
      // Jump nguoc nho (3-30s) → mute
      else if (jump < -3 && jump >= -30 && !_adSkipping) {
        debugPrint('AD INJECT (mute): ${_lastPositionForJump}s → ${positionSec}s');
        _muteForAdSkip();
      }

      // Jump tien > 3s + dang muted → ad xong, content tiep tuc
      if (jump > 3 && _adMuted) {
        debugPrint('AD END: ${_lastPositionForJump}s → ${positionSec}s → unmute');
        _unmuteAfterAdSkip();
      }
    }
    _lastPositionForJump = positionSec;

    // ★ 3. Periodic check moi 2s — bat qua truong hop ad bi lo
    if (now - _lastAdCheckTime > 2000 && !_adMuted) {
      _lastAdCheckTime = now;
      // Check API markers
      for (final ad in _adMarkers) {
        final start = (ad['start_time'] as int?) ?? 0;
        if (positionSec >= start - 3 && positionSec < start + 5) {
          debugPrint('API AD HIT (periodic) at ${positionSec}s → mute');
          _muteForAdSkip();
          return;
        }
      }
      // Check m3u8 zones
      if (_m3u8Result != null && _m3u8Result!.hasAds) {
        final adZone = _m3u8Result!.adZoneAt(positionSec.toDouble());
        if (adZone != null) {
          debugPrint('M3U8 AD HIT (periodic) at ${positionSec}s → mute');
          _muteForAdSkip();
        }
      }
    }
  }

  /// ★ Mute để chặn audio leak trước khi skip ad
  void _muteForAdSkip() {
    if (_adMuted) return;
    _adMuted = true;
    _hlsPlayer?.setVolume(0.0);
    debugPrint('AD SKIP: muted');
  }

  /// ★ Unmute sau khi skip ad xong
  void _unmuteAfterAdSkip() {
    _adUnmuteTimer?.cancel();
    _adUnmuteTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      _adMuted = false;
      final restoreVol = _isMuted ? 0.0 : (_volume > 0 ? _volume : 100.0);
      _hlsPlayer?.setVolume(restoreVol);
      debugPrint('AD SKIP: unmuted, volume=$restoreVol');
    });
  }

  /// ★ Skip ad zone: Mute → Stop → Re-open → Wait ready → Seek → Unmute
  void _skipAdZone(int seekToSec) {
    _adSkipping = true;
    final wasPlaying = _hlsPlayer?.state.playing ?? false;

    // Step 1: MUTE ngay lập tức → zero audio leak
    _muteForAdSkip();

    // Step 2: STOP player → xóa sạch buffer (không đơ)
    _hlsPlayer?.stop().then((_) {
      if (!mounted) return;

      // Step 3: Re-open stream
      _hlsPlayer?.open(Media(_currentUrl));

      // Step 4: Đợi player ready (duration > 0) rồi mới seek
      StreamSubscription? durationSub;
      durationSub = _hlsPlayer!.stream.duration.listen((dur) {
        if (dur.inSeconds <= 0) return; // Chưa load xong
        durationSub?.cancel(); // Chỉ trigger 1 lần

        if (!mounted) return;

        // Player đã ready → seek tới sau ad
        _hlsPlayer!.seek(Duration(seconds: seekToSec)).then((_) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted && wasPlaying) _hlsPlayer?.play();
            // Unmute sau khi video chạy ổn định
            _unmuteAfterAdSkip();
            Future.delayed(const Duration(seconds: 3), () {
              _adSkipping = false;
            });
          });
        });
      });
    });
  }

  // ── Ad overlay simulation ──────────────────────────
  void _showAdOverlay(AdZone adZone) {
    _adMode = true;
    _currentAdZone = adZone;
    _adRemainingSec = adZone.duration.toInt();

    // ★ MUTE + Pause để zero audio leak
    _muteForAdSkip();
    _hlsPlayer?.pause();

    // Start countdown
    _adCountdownTimer?.cancel();
    _adCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      setState(() {
        _adRemainingSec--;
        if (_adRemainingSec <= 0) {
          _dismissAdOverlay();
          timer.cancel();
        }
      });
    });

    setState(() {});
  }

  void _dismissAdOverlay() {
    _adMode = false;
    _adCountdownTimer?.cancel();
    final adZone = _currentAdZone;
    _currentAdZone = null;

    if (adZone == null) return;

    // ★ Stop + Re-open → clear buffer, avoid freeze
    final seekTo = adZone.endTime.toInt() + 2;
    _skipAdZone(seekTo);
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

  // ★ Fix A: Stuck detector — phát hiện player bị treo
  void _startStuckDetector() {
    _stuckDetector?.cancel();
    _stuckTickCount = 0;
    _lastPositionForStuckCheck = 0;
    _stuckDetector = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || _hlsPlayer == null) return;
      final pos = _hlsPlayer!.state.position.inSeconds;
      final playing = _hlsPlayer!.state.playing;

      // Nếu đang "play" nhưng position không thay đổi > 6s
      if (playing && pos > 0 && pos == _lastPositionForStuckCheck) {
        _stuckTickCount++;
        if (_stuckTickCount >= 3) { // 3 ticks x 2s = 6s stuck
          debugPrint('★ STUCK DETECTED: pos=$pos, trying recovery...');
          _stuckTickCount = 0;
          // Thử force play
          _hlsPlayer!.play();
          // Nếu sau 2s nữa vẫn stuck → seek nhỏ rồi play
          Future.delayed(const Duration(seconds: 2), () {
            if (!mounted || _hlsPlayer == null) return;
            final newPos = _hlsPlayer!.state.position.inSeconds;
            if (playing && newPos == pos) {
              debugPrint('★ STUCK RECOVERY: seek+play');
              _hlsPlayer!.seek(Duration(seconds: pos + 1));
              Future.delayed(const Duration(milliseconds: 500), () {
                if (mounted) _hlsPlayer?.play();
              });
            }
          });
        }
      } else {
        _stuckTickCount = 0;
      }
      _lastPositionForStuckCheck = pos;
    });
  }

  // ★ Fix B: State sync — sync _isPlaying với player thực mỗi 1s
  void _startStateSync() {
    _stateSyncTimer?.cancel();
    _stateSyncTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _hlsPlayer == null) return;
      final actualPlaying = _hlsPlayer!.state.playing;
      // Sync _isPlaying nếu khác player thực
      if (_isPlaying != actualPlaying && mounted) {
        setState(() => _isPlaying = actualPlaying);
      }
      // Sync position nếu player đang play nhưng _currentPos không update
      if (actualPlaying) {
        final actualPos = _hlsPlayer!.state.position;
        if (actualPos.inSeconds > 0 && !_isDragging) {
          _currentPos = actualPos;
        }
      }
    });
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
    if (_watchRoomActive || _adMode) return;
    if (!_seekCompleted && _currentPosition > 15) return;
    // Dedup: skip if save in-flight or too recent (< 3s)
    if (_isSaving) return;
    if (_lastSaveTime != null && DateTime.now().difference(_lastSaveTime!).inSeconds < 3) return;
    _isSaving = true;
    try {
    int pos = 0;
    int dur = 0;
    if (_playerMode == _PlayerMode.hls && _hlsPlayer != null) {
      pos = _hlsPlayer!.state.position.inSeconds;
      dur = _hlsPlayer!.state.duration.inSeconds;
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

  Future<void> _checkPipAvailability() async {
    try {
      _pipAvailable = await _pipChannel.invokeMethod('isPipAvailable') ?? false;
    } catch (_) {
      _pipAvailable = false;
    }
    // Lắng nghe callback từ iOS native
    _pipChannel.setMethodCallHandler((call) async {
      if (call.method == 'onPipStarted') {
        debugPrint('PiP: native callback — pausing main video');
        // iOS: pause vì PiP dùng AVPlayer riêng
        // Android: KHÔNG pause vì PiP dùng Flutter surface
        if (Platform.isIOS) {
          _hlsPlayer?.pause();
        }
      }
    });
    if (mounted) setState(() {});
  }

  bool _pipActive = false; // Guard: PiP đang active → không auto start lại
  Timer? _pipPollTimer;   // Poll PiP position mỗi 1s

  /// Bắt đầu poll PiP position (gọi khi PiP start)
  void _startPipPoll() {
    _pipPollTimer?.cancel();
    _pipPollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final isActive = await _pipChannel.invokeMethod('isPipActive') ?? false;
        if (!isActive && _pipActive) {
          _pipActive = false;
          _pipPollTimer?.cancel();
          debugPrint('PiP: poll detected stopped');

          if (Platform.isIOS) {
            // iOS: PiP dùng AVPlayer riêng → seek video chính về position PiP
            final position = await _pipChannel.invokeMethod('getPipPosition') ?? 0.0;
            if (position > 0 && _hlsPlayer != null) {
              await _hlsPlayer!.seek(Duration(seconds: (position as double).toInt()));
              _hlsPlayer!.play();
              final restoreVol = _isMuted ? 0.0 : (_volume > 0 ? _volume : 100.0);
              await Future.delayed(const Duration(milliseconds: 200));
              _hlsPlayer!.setVolume(restoreVol);
              debugPrint('PiP: seeked to ${position}s');
            }
          } else {
            // Android: video vẫn chạy trong PiP → chỉ restore volume
            final restoreVol = _isMuted ? 0.0 : (_volume > 0 ? _volume : 100.0);
            _hlsPlayer?.setVolume(restoreVol);
          }
        }
      } catch (_) {}
    });
  }

  /// Setup PiP controller — gọi 1 lần khi video load xong (iOS cần AVPlayer sẵn)
  Future<void> _setupPip() async {
    if (!_pipAvailable || _currentUrl.isEmpty) return;
    final position = _hlsPlayer?.state.position.inSeconds.toDouble() ?? 0;
    try {
      await _pipChannel.invokeMethod('setupPip', {
        'url': _currentUrl,
        'position': position,
        'headers': {
          'Referer': AppConfig.baseUrl,
          'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
        },
      });
    } catch (_) {}
  }

  /// Bật PiP — pass vị trí hiện tại + bắt đầu poll position
  Future<void> _startPip() async {
    final position = _hlsPlayer?.state.position.inSeconds.toDouble() ?? 0;
    _pipActive = true;
    try {
      final result = await _pipChannel.invokeMethod('startPip', {'position': position});
      debugPrint('PiP: startPip result=$result, position=$position');
      _startPipPoll();
    } catch (e) {
      debugPrint('PiP: startPip ERROR=$e');
      _pipActive = false;
    }
  }

  /// Update PiP URL khi chuyển tập
  Future<void> _updatePipUrl() async {
    if (!_pipAvailable || _currentUrl.isEmpty) return;
    try {
      await _pipChannel.invokeMethod('updatePipUrl', {'url': _currentUrl});
    } catch (_) {}
  }

  Future<void> _showAirPlayPicker() async {
    try {
      await _airplayChannel.invokeMethod('showRoutePicker');
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Lưu vị trí hiện tại trước khi app vào background
      if (_hlsPlayer != null) {
        _positionBeforePause = _hlsPlayer!.state.position.inSeconds;
        _saveCurrentProgress();
      }
    } else if (state == AppLifecycleState.resumed) {
      // Re-enable wakelock khi quay lại app
      WakelockPlus.enable();

      // Quay lại app → restore audio session + volume
      if (_hlsPlayer != null) {
        // Restore volume theo user setting
        final restoreVol = _isMuted ? 0.0 : (_volume > 0 ? _volume : 100.0);
        _hlsPlayer!.setVolume(restoreVol);

        // ★ FIX: Nếu position bị reset về 0 → seek lại vị trí trước đó
        final currentPos = _hlsPlayer!.state.position.inSeconds;
        if (_positionBeforePause > 15 && currentPos < 5) {
          _hlsPlayer!.seek(Duration(seconds: _positionBeforePause)).then((_) {
            final restoreVol2 = _isMuted ? 0.0 : (_volume > 0 ? _volume : 100.0);
            _hlsPlayer!.setVolume(restoreVol2);
            _hlsPlayer!.play();
          });
        }
      }

      // Quay lại app → nếu PiP vừa tắt → seek video đến vị trí mới
      if (_pipActive) {
        _pipActive = false;
        _pipPollTimer?.cancel();
        _pipChannel.invokeMethod('getPipPosition').then((pos) {
          final position = (pos as double?) ?? 0;
          if (position > 0 && _hlsPlayer != null) {
            _hlsPlayer!.seek(Duration(seconds: position.toInt())).then((_) {
              // ★ FIX: restore volume to ensure audio is loud after PIP
              final restoreVol = _isMuted ? 0.0 : (_volume > 0 ? _volume : 100.0);
              _hlsPlayer!.setVolume(restoreVol);
              _hlsPlayer!.play();
            });
          }
        });
      }

      // ★ Fix E: Sync state với player thực khi resume
      if (mounted && _hlsPlayer != null) {
        final actualPlaying = _hlsPlayer!.state.playing;
        if (_isPlaying != actualPlaying) {
          setState(() => _isPlaying = actualPlaying);
        }
        final actualPos = _hlsPlayer!.state.position;
        if (actualPos.inSeconds > 0) {
          _currentPos = actualPos;
        }
      }
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable(); // Bật lại màn hình khóa khi thoát
    _unlockBrightness(); // Restore độ sáng gốc
    _healthCheckTimer?.cancel();
    _autoHideControlsTimer?.cancel();
    _clockTimer?.cancel();
    _positionSub?.cancel();
    _playingSub?.cancel();
    _stuckDetector?.cancel();
    _stateSyncTimer?.cancel();
    _adCountdownTimer?.cancel();
    _adUnmuteTimer?.cancel();
    _doubleTapTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _saveProgressOnExit();
    ActivityService.stopWatching();
    _restoreOrientations();
    _hlsPlayer?.dispose();
    _webController?.dispose();
    super.dispose();
  }

  // ── Brightness lock ─────────────────────────────────
  Future<void> _lockBrightness() async {
    try {
      _originalBrightness = await ScreenBrightness().current;
      await ScreenBrightness().setScreenBrightness(1.0);
      _brightnessLocked = true;
    } catch (_) {}
  }

  Future<void> _unlockBrightness() async {
    if (!_brightnessLocked) return;
    try {
      await ScreenBrightness().setScreenBrightness(_originalBrightness);
      _brightnessLocked = false;
    } catch (_) {}
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
    _doubleTapTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() { _showDoubleTapLeft = false; _showDoubleTapRight = false; });
    });
  }

  // ── Long-press 2x speed ─────────────────────────────
  void _onLongPressStart() {
    _speedBeforeLongPress = _playbackSpeed;
    _isLongPressSpeedUp = true;
    _hlsPlayer?.setRate(2.0);
    setState(() {});
  }

  void _onLongPressEnd() {
    _isLongPressSpeedUp = false;
    _hlsPlayer?.setRate(_speedBeforeLongPress);
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
        _adMarkers = [];
        _initHlsPlayer(url);
        _fetchAdMarkers(url, _currentServerName);
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
      if (m3u8.isNotEmpty) {
        _currentUrl = m3u8;
        _adMarkers = []; // Reset ad markers cho tap moi
        _initHlsPlayer(m3u8);
        _fetchAdMarkers(m3u8, _currentServerName);
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
  bool _seekCompleted = false; // Flag để track seek đã hoàn thành
  bool _watchRoomActive = false; // Watch room đang mở → chặn save
  int _positionBeforePause = 0; // Vị trí trước khi app vào background
  StreamSubscription<Duration>? _durationSub; // Lắng nghe duration
  int _seekTargetTime = 0; // Thời gian seek đang nhắm tới (chống position nhảy)
  int _lastPosForAdCheck = -1; // Position trước đó để detect crossed ad zone
  bool _isSaving = false; // Dedup concurrent save requests
  DateTime? _lastSaveTime; // Minimum interval between saves

  // ── Ad markers ──
  List<Map<String, dynamic>> _adMarkers = [];
  bool _adSkipping = false; // Dang skip ad → khong trigger lai

  // ── M3U8 Ad Parser ──
  final M3u8AdParser _adParser = M3u8AdParser();
  M3u8ParseResult? _m3u8Result;
  bool _adMode = false;        // Đang hiển thị overlay ad?
  int _adRemainingSec = 0;     // Đếm ngược ad
  Timer? _adCountdownTimer;
  AdZone? _currentAdZone;      // Ad zone hiện tại
  bool _adMuted = false;       // Đã mute để chống audio leak
  int _lastPositionForJump = -1; // Track position để detect jump (ad injection)
  Timer? _adUnmuteTimer;       // Timer unmute sau khi skip ad

  int _lastSeekByUser = 0;
  String _currentServerName = '';

  // ── Subtitles ──
  final SrtParser _srtParser = SrtParser();
  List<SubtitleEntry> _subtitles = [];
  bool _subtitleEnabled = false;
  String? _currentSubtitleUrl;

  // ── Brightness lock ──
  double _originalBrightness = 1.0;
  bool _brightnessLocked = false;

  // ── Double-click visual feedback ──
  bool _showDoubleTapLeft = false;
  bool _showDoubleTapRight = false;
  Timer? _doubleTapTimer;
  double _doubleTapProgress = 0;

  // ── Long-press 2x speed ──
  bool _isLongPressSpeedUp = false;
  double _speedBeforeLongPress = 1.0;

  void _initHlsPlayer(String url) {
    _hlsPlayer ??= Player();
    _videoController ??= VideoController(_hlsPlayer!);
    _healthCheckTimer?.cancel();
    _positionSub?.cancel();
    _playingSub?.cancel();
    _durationSub?.cancel();
    _playerReady = false;
    _seekCompleted = _currentPosition <= 15; // Nếu không cần seek → true ngay

    // Lắng nghe position để hiện/ẩn skip intro + detect seek + update custom controls
    _positionSub = _hlsPlayer!.stream.position.distinct().listen((pos) {
      final sec = pos.inSeconds;
      final showSkip = sec >= 10 && sec <= 120;
      if (showSkip != _showSkipIntro && mounted) {
        setState(() => _showSkipIntro = showSkip);
      }

      // Auto-skip ad zone
      _checkAdZone(sec);

      // Update custom controls position (throttle UI update mỗi 500ms)
      if (mounted && !_isDragging) {
        // ★ FIX: Bỏ qua position updates gần seek target — chờ player arrive
        final posSec = pos.inSeconds;
        if (_seekTargetTime > 0) {
          if ((posSec - _seekTargetTime).abs() <= 5) {
            // Player đã gần target → xác nhận seek thành công
            _seekTargetTime = 0;
          } else if (posSec.abs() < _seekTargetTime - 5 || posSec > _seekTargetTime + 15) {
            // Position chưa đến target hoặc sai quá → KHÔNG update UI
            // (tránh slider nhảy lung tung)
            return;
          }
        }

        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastPositionUpdate > 500) {
          _lastPositionUpdate = now;
          _currentPos = pos;
          setState(() {});
        }
      }

      // Detect seek: nếu position nhảy > 5s so với lần lưu trước → lưu ngay
      final diff = (pos.inSeconds - _lastSavedPosition).abs();
      if (diff > 5 && pos.inSeconds > 0) {
        _lastSavedPosition = pos.inSeconds;
        _saveCurrentProgress();
      }
    });

    // Lắng nghe playing state → hiện Video khi bắt đầu phát + update custom controls
    // CHẶN auto-play nếu chưa seek xong
    _playingSub = _hlsPlayer!.stream.playing.listen((playing) {
      if (playing && !_playerReady && mounted) {
        setState(() => _playerReady = true);
      }
      // Nếu đang play nhưng chưa seek xong → pause lại
      if (playing && !_seekCompleted && mounted) {
        _hlsPlayer!.pause();
      }
      // Update custom controls
      if (mounted) {
        setState(() => _isPlaying = playing);
      }
    });

    // Lắng nghe duration → media đã load xong → seek ngay + update custom controls
    _durationSub = _hlsPlayer!.stream.duration.distinct().listen((dur) {
      if (dur.inSeconds > 0 && !_seekCompleted && _currentPosition > 15 && mounted) {
        _seekToPosition();
      }
      // Update custom controls duration
      if (mounted) {
        setState(() => _currentDur = dur);
      }
    });

    // Buffering listener - chỉ play khi seek đã hoàn thành
    _hlsPlayer!.stream.buffering.listen((buffering) {
      if (!buffering && mounted && !_hlsPlayer!.state.playing && _seekCompleted) {
        _hlsPlayer!.play();
      }
    });

    // Web: dùng proxy để tránh CORS | Mobile: dùng URL trực tiếp
    final mediaUrl = kIsWeb ? AppConfig.proxyHlsUrl(url) : url;
    final mediaHeaders = kIsWeb
        ? <String, String>{} // Proxy đã handle headers
        : {
            'Referer': AppConfig.baseUrl,
            'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
          };

    _hlsPlayer!.open(
      Media(mediaUrl, httpHeaders: mediaHeaders),
    ).then((_) {
      if (!mounted) return;
      _playerReady = true;
      setState(() => _isLoading = false);

      // ★ Parse m3u8 for ad detection (async, non-blocking)
      if (url.contains('.m3u8')) {
        _parseM3u8ForAds(url);
      }

      // Setup PiP controller (iOS) — tạo AVPlayer sẵn khi video load
      _setupPip();

      // Nếu không cần seek → play ngay
      if (_currentPosition <= 15) {
        _seekCompleted = true;
        _hlsPlayer!.play();
      }
      // Nếu cần seek → đợi duration listener xử lý

      _startProgressTimer();
      _startStuckDetector();
      _startStateSync();
      _reportHealth('ok');
    }).catchError((e) {
      _fallbackToEmbed();
      return null;
    });

    // Health check: nếu sau 8s player vẫn stuck ở 0 → fallback embed
    _healthCheckTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _hlsPlayer == null) return;
      final pos = _hlsPlayer!.state.position.inSeconds;
      final playing = _hlsPlayer!.state.playing;
      if (pos == 0 && !playing) {
        _fallbackToEmbed();
      }
    });
  }

  /// Seek đến _currentPosition - gọi khi duration đã available
  Future<void> _seekToPosition() async {
    if (_seekCompleted || _currentPosition <= 15) return;

    // Pause để chặn auto-play
    _hlsPlayer!.pause();
    await Future.delayed(const Duration(milliseconds: 200));

    _seekTargetTime = _currentPosition;

    // Seek
    await _hlsPlayer!.seek(Duration(seconds: _currentPosition));
    await Future.delayed(const Duration(milliseconds: 300));

    // Seek xong → cho phép save + play
    _seekCompleted = true;
    if (mounted) {
      _hlsPlayer!.play();
    }
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

    // Lấy vị trí hiện tại TRƯỚC KHI chuyển server
    int currentPosition = 0;
    if (_playerMode == _PlayerMode.hls && _hlsPlayer != null) {
      currentPosition = _hlsPlayer!.state.position.inSeconds;
    } else if (_playerMode == _PlayerMode.embed && _webController != null) {
      currentPosition = _currentPosition;
    }
    if (currentPosition <= 0) currentPosition = _currentPosition;

    // Lưu progress ngay lập tức (bypass _seekCompleted check)
    _saveProgressImmediate(currentPosition);

    // Tìm tập tương ứng trên server mới (theo ep_slug hoặc index)
    final currentEps = _currentServerEps;
    Map<String, dynamic>? matchingEp;

    if (_currentEpId != null && currentEps.isNotEmpty) {
      // Tìm tập đang xem trên server cũ
      final currentEp = currentEps.where((e) => e['id'] == _currentEpId).toList();
      if (currentEp.isNotEmpty) {
        final currentSlug = (currentEp.first['ep_slug'] ?? '').toString();
        final currentIndex = currentEps.indexOf(currentEp.first);

        // Tìm trên server mới theo ep_slug trước
        final newEps = (_servers[newServerIdx]['episodes'] as List<dynamic>?)
                ?.cast<Map<String, dynamic>>() ?? [];
        if (currentSlug.isNotEmpty) {
          final bySlug = newEps.where((e) => e['ep_slug'] == currentSlug).toList();
          if (bySlug.isNotEmpty) matchingEp = bySlug.first;
        }
        // Fallback: tìm theo index
        if (matchingEp == null && currentIndex < newEps.length) {
          matchingEp = newEps[currentIndex];
        }
      }
    }

    setState(() {
      _selectedServer = newServerIdx;
      _currentPosition = currentPosition; // Giữ nguyên vị trí
      _epPage = 1; // Reset page when switching server
      _sheetEpPage = 1;
    });

    // Nếu tìm thấy tập tương ứng → chuyển và giữ nguyên vị trí
    if (matchingEp != null) {
      _switchEpisode(matchingEp, keepPosition: true);
    }
  }

  // ── Chuyển tập ────────────────────────────────────
  void _switchEpisode(Map<String, dynamic> ep, {bool keepPosition = false}) {
    // Show interstitial on episode switch (frequency-capped)
    SmartLinkService.showInterstitialIfNeeded(context, onDone: () {
      _doSwitchEpisode(ep, keepPosition: keepPosition);
    });
  }

  void _doSwitchEpisode(Map<String, dynamic> ep, {bool keepPosition = false}) {
    _hasSwitchedEp = true; // Danh dau da chuyen tap
    // Luu progress tap hien tai truoc khi chuyen
    if (!keepPosition) _saveCurrentProgress();

    final epId = ep['id'];
    final m3u8 = (ep['link_m3u8'] ?? '').toString().trim();
    final embed = (ep['link_embed'] ?? '').toString().trim();
    _currentEmbedUrl = embed; // lưu để fallback

    // Ưu tiên HLS cho tất cả (mobile chạy được hết)
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
      if (!keepPosition) {
        _currentPosition = 0;
        _lastSavedPosition = 0;
        _seekTargetTime = 0;
        _seekCompleted = false;
        _lastPositionForJump = -1; // Reset ad tracking
        _adMarkers = [];
        _m3u8Result = null;
        _adMuted = false;
        _adSkipping = false;
        _subtitles = []; // Reset subtitles for new episode
      }
    });

    // Load subtitles for new episode
    _loadSubtitles(ep);

    if (useHls) {
      _hlsPlayer?.stop(); // Dừng player cũ
      _adMarkers = [];
      _initHlsPlayer(url);
      _fetchAdMarkers(url, _currentServerName);
      // Update PiP URL cho iOS (chuyển tập → PiP cũng phải update)
      _updatePipUrl();
    }

    // Tắt loading sau một khoảng thời gian ngắn hoặc khi player sẵn sàng
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _isLoading = false);
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
        child: isLandscape
            ? Stack(children: [
                Positioned.fill(child: _buildPlayer()),
                if (_showControls)
                  Positioned(
                    top: 8, left: 8,
                    child: GestureDetector(
                      onTap: () {
                        _restoreOrientations();
                        Future.delayed(const Duration(milliseconds: 300), () {
                          _restoreOrientations();
                        });
                      },
                      child: Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                        child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 22),
                      ),
                    ),
                  ),
                // Episode selector button (bên phải giữa màn hình)
                if (_showControls && _servers.isNotEmpty)
                  Positioned(
                    top: 0, bottom: 0, right: 12,
                    child: Center(
                      child: GestureDetector(
                        onTap: _showEpisodeSheet,
                        child: Container(
                          width: 44, height: 44,
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: const AppSvgIcon('list-video.svg', size: 24, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
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
                // Player
                AspectRatio(aspectRatio: 16 / 9, child: _buildPlayer()),
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
                              avatarUrl: auth.isLoggedIn ? (auth.user?['avatar']?.toString()) : null,
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
    final movieId = widget.movieId;
    final epId = _currentEpId;
    if (movieId <= 0) return;

    // DỪNG video trước, rồi lấy position
    if (_playerMode == _PlayerMode.hls && _hlsPlayer != null) {
      _hlsPlayer!.pause();
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
    if (_playerMode == _PlayerMode.hls && _hlsPlayer != null) {
      pos = _hlsPlayer!.state.position.inSeconds;
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
        _positionSub?.cancel();
        _playingSub?.cancel();
        await _saveCurrentProgress();

        // Pause player NGAY
        _hlsPlayer?.pause();
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
            _startStateSync();
            await _loadWatchProgress();
            if (_hlsPlayer != null && _currentPosition > 3) {
              _seekCompleted = false;
              await _hlsPlayer!.seek(Duration(seconds: _currentPosition));
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
                  SmartLinkService.showInterstitialIfNeeded(context, onDone: () {
                    Navigator.pop(context);
                  });
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
              // Badge player mode (debug only)
              if (kDebugMode)
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
        // Real banner ad (SmartLink)
        SmartLinkBannerWidget(),
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

  // ── Player — hybrid HLS / WebView ─────────────────
  Widget _buildPlayer() {
    return Stack(
        fit: StackFit.expand,
        children: [
          // ── HLS native player (media_kit) — dùng NoVideoControls, custom controls bên dưới ──
          if (_playerMode == _PlayerMode.hls && _videoController != null && _playerReady)
            SizedBox.expand(
              child: Video(controller: _videoController!, controls: NoVideoControls),
            ),

          // ── Black overlay khi PiP active — CHỈ iOS (Android dùng Flutter surface → video tự hiện) ──
          if (_pipActive && Platform.isIOS)
            Container(
              color: Colors.black,
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AppSvgIcon('picture-in-picture-2.svg', size: 48, color: Colors.white38),
                  const SizedBox(height: 8),
                  const Text('Đang phát trong PiP', style: TextStyle(color: Colors.white54, fontSize: 14)),
                ]),
              ),
            ),

          // ── Buffering indicator (hiện khi HLS đang load nhưng chưa phát) ──
          if (_playerMode == _PlayerMode.hls && _hlsPlayer != null && !_playerReady && !_isLoading)
            const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(color: AppTheme.accent, strokeWidth: 3),
                SizedBox(height: 12),
                Text('Đang tải video...', style: TextStyle(color: Colors.white54, fontSize: 13)),
              ]),
            ),

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
                _startStateSync();
                _reportHealth('ok');
              },
              onReceivedError: (_, __, ___) {
                if (mounted) setState(() { _error = 'Không thể tải video'; _isLoading = false; });
              },
            ),

          // ── Gesture zones: tap = show/hide controls, double-tap = seek, long-press = 2x ──
          if (_playerMode == _PlayerMode.hls && _playerReady)
            Stack(
              children: [
                Row(
                  children: [
                    // LEFT zone: tap, double-tap = lùi 10s, long-press = 2x
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
                          final pos = _hlsPlayer?.state.position ?? Duration.zero;
                          final target = max(0, pos.inSeconds - 10);
                          _seekTargetTime = target;
                          _lastSeekByUser = DateTime.now().millisecondsSinceEpoch;
                          if (mounted) setState(() => _currentPos = Duration(seconds: target));
                          _hlsPlayer?.seek(Duration(seconds: target));
                          _showDoubleTapFeedback(false);
                        },
                        onLongPressStart: (_) => _onLongPressStart(),
                        onLongPressEnd: (_) => _onLongPressEnd(),
                        onLongPressCancel: () => _onLongPressEnd(),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    // CENTER zone: tap = toggle controls
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
                        child: const SizedBox.expand(),
                      ),
                    ),
                    // RIGHT zone: tap, double-tap = tới 10s, long-press = 2x
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
                          final pos = _hlsPlayer?.state.position ?? Duration.zero;
                          final target = pos.inSeconds + 10;
                          _seekTargetTime = target;
                          _lastSeekByUser = DateTime.now().millisecondsSinceEpoch;
                          if (mounted) setState(() => _currentPos = Duration(seconds: target));
                          _hlsPlayer?.seek(Duration(seconds: target));
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
          if (_showControls && _isLandscape && _playerMode == _PlayerMode.hls && _playerReady) ...[
            // Top bar: back+lock | title | pip+airplay+episodes
            Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),
            // Center: prev|rewind10|play|forward10|next
            Positioned(
              top: 0, bottom: 0, left: 0, right: 0,
              child: _buildCenterControls(),
            ),
            // Bottom: timeline + toolbar
            Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomBar()),
            // Skip Intro
            if (_showSkipIntro)
              Positioned(bottom: 80, right: 12, child: _skipIntroButton()),
          ],
          // ── Portrait mini controls — chỉ hiện khi portrait + HLS ──
          if (_showControls && !_isLandscape && _playerMode == _PlayerMode.hls && _playerReady)
            Positioned(bottom: 0, left: 0, right: 0, child: _buildPortraitMiniControls()),

          // ── Loading ──
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(color: AppTheme.accent, strokeWidth: 3),
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

          // ── Subtitle overlay ──
          if (_subtitleEnabled && _subtitles.isNotEmpty && _playerMode == _PlayerMode.hls)
            Positioned(
              bottom: _showControls ? 70 : 20,
              left: 20,
              right: 20,
              child: Builder(
                builder: (context) {
                  final text = _getSubtitleForPosition(_currentPos);
                  if (text == null) return const SizedBox.shrink();
                  final colorHex = int.parse('0xFF${_selectedSubtitleColor.substring(1)}');
                  return Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(colorHex),
                      fontSize: _selectedSubtitleSize,
                      fontWeight: FontWeight.w600,
                      shadows: [
                        const Shadow(blurRadius: 4, color: Colors.black87, offset: Offset(1, 1)),
                        const Shadow(blurRadius: 8, color: Colors.black54, offset: Offset(-1, -1)),
                      ],
                    ),
                  );
                },
              ),
            ),

          // ── Ad overlay simulation ──
          if (_adMode)
            Positioned.fill(
              child: Container(
                color: Colors.black87,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.ad_units, color: Colors.amber, size: 48),
                      const SizedBox(height: 12),
                      const Text(
                        'Quảng cáo',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '$_adRemainingSec giây',
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Progress bar
                      SizedBox(
                        width: 200,
                        child: LinearProgressIndicator(
                          value: _currentAdZone != null && _currentAdZone!.duration > 0
                              ? (_currentAdZone!.duration - _adRemainingSec) / _currentAdZone!.duration
                              : 0,
                          backgroundColor: Colors.white24,
                          valueColor: const AlwaysStoppedAnimation(Colors.amber),
                        ),
                      ),
                      const SizedBox(height: 16),
                      GestureDetector(
                        onTap: _dismissAdOverlay,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white38),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text('Bỏ qua ▸', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
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

  Widget _skipIntroButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_hlsPlayer == null) return;
        final current = _hlsPlayer!.state.position.inSeconds;
        final target = current + 120;
        _seekTargetTime = target;
        if (mounted) setState(() => _currentPos = Duration(seconds: target));
        _hlsPlayer!.seek(Duration(seconds: target));
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
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1C21),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.85,
          minChildSize: 0.3,
          expand: false,
          builder: (ctx, scrollController) {
            return StatefulBuilder(
              builder: (context, setSheetState) {
                return Column(
                  children: [
                    // Handle bar
                    Container(
                      margin: const EdgeInsets.only(top: 12, bottom: 8),
                      width: 36, height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    // Title + Server tabs
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.playlist_play_rounded, color: Colors.white, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                'Chọn tập',
                                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                          // Server tabs — tất cả nguồn đều sống
                          if (_servers.length > 1) ...[
                            const SizedBox(height: 10),
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: _servers.asMap().entries.map((entry) {
                                  final idx = entry.key;
                                  final server = entry.value;
                                  final serverName = server['server_name']?.toString() ?? 'Server ${idx + 1}';
                                  final isActive = idx == _selectedServer;

                                  return GestureDetector(
                                    onTap: () {
                                      // Cập nhật cả outer state VÀ sheet state
                                      setState(() {
                                        _selectedServer = idx;
                                        _sheetEpPage = 1; // Reset page on server switch
                                      });
                                      setSheetState(() {});
                                    },
                                    child: Container(
                                      margin: const EdgeInsets.only(right: 8),
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: isActive
                                            ? AppTheme.accent.withValues(alpha: 0.15)
                                            : Colors.white.withValues(alpha: 0.05),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                          color: isActive ? AppTheme.accent : Colors.white24,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // Dot xanh — tất cả đều sống
                                          Container(
                                            width: 6, height: 6,
                                            decoration: BoxDecoration(
                                              color: isActive ? AppTheme.accent : Colors.green,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            serverName,
                                            style: TextStyle(
                                              color: isActive ? AppTheme.accent : Colors.white70,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const Divider(color: Colors.white12, height: 1),
                    // Episodes grid (includes page chips internally)
                    Expanded(
                      child: _buildEpisodeList(scrollController, setSheetState),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
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
                  _switchEpisode(ep);
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
            GestureDetector(
              onTap: () {
                _restoreOrientations();
                Future.delayed(const Duration(milliseconds: 300), () => _restoreOrientations());
              },
              child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 16),
            GestureDetector(
              onTap: () {},
              child: Icon(Icons.lock_outline, color: Colors.white.withValues(alpha: 0.7), size: 20),
            ),
            Expanded(
              child: Center(
                child: Text(
                  widget.movieTitle ?? '',
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (_pipAvailable)
              GestureDetector(
                onTap: _startPip,
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
              final pos = _hlsPlayer?.state.position ?? Duration.zero;
              final target = max(0, pos.inSeconds - 10);
              _seekTargetTime = target;
              _lastSeekByUser = DateTime.now().millisecondsSinceEpoch;
              if (mounted) setState(() => _currentPos = Duration(seconds: target));
              _hlsPlayer?.seek(Duration(seconds: target));
              _showDoubleTapFeedback(false);
            },
            onLongPressStart: (_) => _onLongPressStart(),
            onLongPressEnd: (_) => _onLongPressEnd(),
            onLongPressCancel: () => _onLongPressEnd(),
            child: const SizedBox.expand(),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () {
                  final eps = _currentServerEps;
                  for (int i = 0; i < eps.length; i++) {
                    if (eps[i]['id'] == _currentEpId && i > 0) {
                      _switchEpisode(eps[i - 1]);
                      break;
                    }
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(Icons.skip_previous_rounded, color: Colors.white.withValues(alpha: 0.5), size: 28),
                ),
              ),
              GestureDetector(
                onTap: () {
                  final pos = _hlsPlayer?.state.position ?? Duration.zero;
                  final target = max(0, pos.inSeconds - 10);
                  _seekTargetTime = target;
                  if (mounted) setState(() => _currentPos = Duration(seconds: target));
                  _hlsPlayer?.seek(Duration(seconds: target));
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: AppSvgIcon('rewind.svg', size: 30, color: Colors.white),
                ),
              ),
              GestureDetector(
                onTap: () {
                  if (_isPlaying) { _hlsPlayer?.pause(); } else { _hlsPlayer?.play(); }
                },
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
              GestureDetector(
                onTap: () {
                  final pos = _hlsPlayer?.state.position ?? Duration.zero;
                  final target = pos.inSeconds + 10;
                  _seekTargetTime = target;
                  if (mounted) setState(() => _currentPos = Duration(seconds: target));
                  _hlsPlayer?.seek(Duration(seconds: target));
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: AppSvgIcon('fast-forward.svg', size: 30, color: Colors.white),
                ),
              ),
              _nextEpisodeButton(),
            ],
          ),
        ),
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
              final pos = _hlsPlayer?.state.position ?? Duration.zero;
              final target = pos.inSeconds + 10;
              _seekTargetTime = target;
              _lastSeekByUser = DateTime.now().millisecondsSinceEpoch;
              if (mounted) setState(() => _currentPos = Duration(seconds: target));
              _hlsPlayer?.seek(Duration(seconds: target));
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

  Widget _buildBottomBar() {
    final progress = _currentDur.inSeconds > 0
        ? _currentPos.inSeconds / _currentDur.inSeconds
        : 0.0;
    final displayValue = _isDragging ? _dragValue : progress;
    final currentTime = _isDragging
        ? Duration(seconds: (_dragValue * _currentDur.inSeconds).toInt())
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
                      final targetSec = (value * _currentDur.inSeconds).toInt();
                      _seekTargetTime = targetSec;
                      _lastSeekByUser = DateTime.now().millisecondsSinceEpoch;
                      if (mounted) setState(() => _currentPos = Duration(seconds: targetSec));
                      _hlsPlayer?.seek(Duration(seconds: targetSec));
                    },
                  ),
                ),
              ),
              Text(
                _formatDuration(_currentDur),
                style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.w500),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildToolbarItem(Icons.aspect_ratio_rounded, 'Tỷ lệ', () {}),
              const SizedBox(width: 40),
              _buildToolbarItem(Icons.mic_none_rounded, 'Server', _showServerPopup),
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
                      value: (_currentDur.inSeconds > 0 ? _currentPos.inSeconds / _currentDur.inSeconds : 0.0).clamp(0.0, 1.0),
                      onChanged: (v) {
                        final t = (v * _currentDur.inSeconds).toInt();
                        _hlsPlayer?.seek(Duration(seconds: t));
                        if (mounted) setState(() => _currentPos = Duration(seconds: t));
                      },
                    ),
                  ),
                ),
                Text(_formatDuration(_currentDur), style: TextStyle(color: Colors.white38, fontSize: 10, fontFamily: 'monospace')),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTap: () {
                    if (_isPlaying) { _hlsPlayer?.pause(); } else { _hlsPlayer?.play(); }
                  },
                  child: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 28),
                ),
                GestureDetector(
                  onTap: () {
                    final pos = _hlsPlayer?.state.position ?? Duration.zero;
                    final target = max(0, pos.inSeconds - 10);
                    _hlsPlayer?.seek(Duration(seconds: target));
                  },
                  child: const AppSvgIcon('rewind.svg', size: 22, color: Colors.white),
                ),
                GestureDetector(
                  onTap: () {
                    final pos = _hlsPlayer?.state.position ?? Duration.zero;
                    final target = pos.inSeconds + 10;
                    _hlsPlayer?.seek(Duration(seconds: target));
                  },
                  child: const AppSvgIcon('fast-forward.svg', size: 22, color: Colors.white),
                ),
                if (_subtitles.isNotEmpty)
                  GestureDetector(
                    onTap: () => setState(() => _subtitleEnabled = !_subtitleEnabled),
                    child: Icon(Icons.subtitles_rounded, size: 20, color: _subtitleEnabled ? AppTheme.accent : Colors.white70),
                  ),
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

  void _cycleSpeed() {
    final idx = _speeds.indexOf(_playbackSpeed);
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
                                _hlsPlayer?.setVolume(val);
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
              // PiP button
              if (_pipAvailable)
                GestureDetector(
                  onTap: _startPip,
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
              // Mic button → server popup
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
      _hlsPlayer?.setRate(_playbackSpeed);
    });
  }

  void _showSettingsPopup() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.6,
              decoration: const BoxDecoration(
                color: Color(0xFF1E2026),
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Column(
                children: [
                  // Handle bar
                  Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 16),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // Header with back button
                  if (_settingsPanel != 'main')
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () {
                              setModalState(() => _settingsPanel = 'main');
                            },
                            child: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _settingsPanel == 'quality' ? 'Chất lượng' :
                            _settingsPanel == 'subtitles' ? 'Phụ đề' : 'Tốc độ',
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  // Content
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: _settingsPanel == 'main'
                          ? _buildMainPanel(setModalState)
                          : _settingsPanel == 'quality'
                              ? _buildQualityPanel(setModalState)
                              : _settingsPanel == 'subtitles'
                                  ? _buildSubtitlesPanel(setModalState)
                                  : _buildSpeedPanel(setModalState),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
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
    ];
  }

  List<Widget> _buildSpeedPanel(Function setModalState) {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
    return speeds.map((s) => _buildOptionRow('${s}x', _playbackSpeed == s, () {
      setState(() {
        _playbackSpeed = s;
        _hlsPlayer?.setRate(s);
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
    final currentVol = _hlsPlayer?.state.volume ?? 100.0;
    if (currentVol > 0) {
      _volume = currentVol;
      _isMuted = true;
      _hlsPlayer?.setVolume(0.0);
    } else {
      _isMuted = false;
      _hlsPlayer?.setVolume(_volume > 0 ? _volume : 100.0);
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
                              serverName,
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
    if (_playerMode == _PlayerMode.hls && _hlsPlayer != null) {
      final retryUrl = kIsWeb ? AppConfig.proxyHlsUrl(_currentUrl) : _currentUrl;
      _hlsPlayer!.open(Media(retryUrl));
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

          return GestureDetector(
            onTap: () {
              // ★ FIX: Chỉ chọn server, KHÔNG auto-play
              // User phải bấm tập mới play
              setState(() => _selectedServer = i);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: isActive ? AppTheme.accent : const Color(0xFF1E2130),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: isActive ? AppTheme.accent : const Color(0x22FFFFFF),
                ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 6, height: 6,
                  decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  s['server_name']?.toString() ?? 'Server ${i + 1}',
                  style: TextStyle(
                    color: isActive ? const Color(0xFF1A1100) : Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
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
              childAspectRatio: 1.4,
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
                    color: isActive ? AppTheme.accent : const Color(0xFF1E2130),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isActive ? AppTheme.accent : const Color(0x22FFFFFF),
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