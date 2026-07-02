import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../config/app_config.dart';
import '../../config/theme.dart';
import '../../models/watch_room.dart';
import '../../services/movie_service.dart';
import '../../services/watch_party_service.dart';
import '../../services/voice_service.dart';

/// Màn hình phòng xem chung - Native Flutter (không dùng WebView)
class WatchRoomScreen extends StatefulWidget {
  final String roomCode;
  final int initialPosition; // Vị trí ban đầu (giây) — seek ngay khi video load

  const WatchRoomScreen({super.key, required this.roomCode, this.initialPosition = 0});

  @override
  State<WatchRoomScreen> createState() => _WatchRoomScreenState();
}

class _WatchRoomScreenState extends State<WatchRoomScreen> with WidgetsBindingObserver {

  static bool get _isTablet {
    final size = WidgetsBinding.instance.window.physicalSize;
    final shortestSide = size.shortestSide / WidgetsBinding.instance.window.devicePixelRatio;
    return shortestSide >= 600;
  }

  static bool get _isLargeIpad {
    final size = WidgetsBinding.instance.window.physicalSize;
    final shortestSide = size.shortestSide / WidgetsBinding.instance.window.devicePixelRatio;
    return shortestSide > 750;
  }

  static void _restoreOrientations() {
    if (_isLargeIpad) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else if (_isTablet) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
  }
  final WatchPartyService _service = WatchPartyService();
  final MovieService _movieService = MovieService();
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();

  // Video player
  Player? _player;
  VideoController? _videoController;
  bool _isPlayerReady = false;
  bool _isLoading = true;
  String? _error;

  // State
  bool _isHost = false;
  String _videoState = 'paused';
  double _videoTime = 0;
  int _episodeId = 0;
  String _movieName = '';
  String _epName = '';
  bool _isLocalAction = false;
  Timer? _localActionTimer;

  // Guest speed control
  double _playbackSpeed = 1.0;
  static const List<double> _speeds = [0.5, 1.0, 1.5, 2.0, 3.0];

  // Host controls
  bool _showControls = true;
  bool _isPlaying = false; // Track playing state locally
  Timer? _hideControlsTimer;

  // ★ Fix: stuck detector + state sync
  Timer? _stuckDetector;
  Timer? _stateSyncTimer;
  int _lastPositionForStuckCheck = 0;
  int _stuckTickCount = 0;

  // Đồng hồ hiện thị giờ VN (luôn hiện, không ẩn theo tap)
  Timer? _clockTimer;

  // Chat
  final List<ChatMessage> _messages = [];
  int _lastMsgId = 0;

  // Members
  final List<RoomMember> _members = [];
  int _onlineCount = 0;

  // Episodes & Servers
  List<dynamic> _episodes = [];
  List<dynamic> _servers = [];
  int _selectedServer = 0;
  String _sourceType = ''; // HLS / Embed / m3u8
  Map<String, String> _serverHealth = {}; // server_name → 'ok' | 'broken'

  // Movie info (để save watch progress)
  int _movieId = 0;
  String _epSlug = '';

  // Voice
  VoiceService? _voiceService;
  final List<VoiceParticipant> _voiceParticipants = [];
  String _myName = '';

  // Polling
  Timer? _pollTimer;
  bool _isPolling = false;
  int _lastHostSyncMs = 0;

  // Host position sync — cập nhật video_time định kỳ cho guest
  Timer? _hostSyncTimer;

  // Tab
  int _selectedTab = 0; // 0 = Chat, 1 = Info

  // Fullscreen toggles
  bool _showChatInFullscreen = false;
  bool _showEpPanel = false;
  bool _showVolumeInline = false;
  int _unreadMessages = 0;
  int _lastSeenMsgCount = 0;

  // Sync
  bool _initialSyncDone = false;
  Timer? _seekRetryTimer;

  // Timeline drag state
  bool _isDragging = false;
  double _dragValue = 0;
  int _lastPositionUpdate = 0; // throttle position updates

  // Watchtime sync — lưu thời lượng đã xem để resume khi thoát zoom
  double _lastSavedPosition = 0;
  Timer? _watchtimeSaveTimer;

  // Fullscreen state
  bool _isFullscreen = false;
  bool _forcePortrait = false; // Back button → ép portrait, ignore device orientation

  // Password state
  bool _hasPassword = false;

  // Volume (0-100 theo media_kit)
  double _volume = 100.0;
  bool _isMuted = false;

  // ★ AD SKIP FIX: media_kit/libmpv tự skip ad segments trong HLS stream
  // Mobile: position nhảy 900→930 (skip 30s ad) → mobile bị lệch +30s so với web
  // Solution: subtract 30s từ mobile position khi past ad zone
  double _lastKnownPosition = 0;
  int _adSkipRecoverCount = 0;
  static const int _adSkipMaxRecover = 5;
  static const int _adPosition = 900; // vị trí ad bắt đầu (15:00)
  static const int _adDuration = 30;  // ad dài 30s

  // Host vắng mặt
  bool _waitingHostShown = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable(); // Chặn màn hình khóa khi xem phòng
    WidgetsBinding.instance.addObserver(this);
    // Dùng initialPosition ngay — không đợi poll
    if (widget.initialPosition > 3) {
      _videoTime = widget.initialPosition.toDouble();
      _initialSyncDone = true; // Chặn poll ghi đè
    }
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _initPlayer();
    _startPolling();
    _startWatchtimeSave();
    _startHostSync();
    _startStuckDetector();
    _startStateSync();
    // Bắt đầu đồng hồ VN — tick mỗi 200ms để không bị lệch giờ
    _clockTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() {});
    });

    // Init mic ngay khi vào phòng — hiện permission dialog + activate mic hệ thống
    VoiceService.initMic();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _player != null) {
      // Restore volume
      _player!.setVolume(_isMuted ? 0.0 : _volume);
      // ★ Fix E: Sync state với player thực
      final actualPlaying = _player!.state.playing;
      if (_isPlaying != actualPlaying && mounted) {
        setState(() => _isPlaying = actualPlaying);
      }
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable(); // Bật lại màn hình khóa khi thoát
    // Lưu thời lượng trước khi thoát (zoom out / pop screen)
    _saveWatchtime();
    _pollTimer?.cancel();
    _hostSyncTimer?.cancel();
    _localActionTimer?.cancel();
    _clockTimer?.cancel();
    _watchtimeSaveTimer?.cancel();
    _stuckDetector?.cancel();
    _stateSyncTimer?.cancel();
    _durationSub?.cancel();
    _bufferingSub?.cancel();
    _seekRetryTimer?.cancel();
    _chatController.dispose();
    _chatScrollController.dispose();
    _voiceService?.dispose();
    _player?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    // Restore UI khi thoát
    _restoreOrientations();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _initPlayer() {
    _player = Player();
    _videoController = VideoController(_player!);

    // Listen to player events
    _player!.stream.playing.listen((playing) {
      setState(() => _isPlaying = playing);
      if (_isLocalAction) return;
      if (_isHost) {
        _updateHostState(playing ? 'playing' : 'paused');
      }
    });

    _player!.stream.position.listen((pos) {
      if (!mounted || _isDragging) return;

      final posSec = pos.inSeconds.toDouble();

      // ★ AD SKIP FIX: media_kit nhảy về 0 khi skip ad
      // Khôi phục: seek về vị trí trước ad (để player load lại từ đó)
      if (posSec < 10 && _lastKnownPosition > 300 && _adSkipRecoverCount < _adSkipMaxRecover) {
        final recoverTo = _lastKnownPosition;
        _adSkipRecoverCount++;
        _setLocalAction();
        _player!.seek(Duration(seconds: recoverTo.toInt()));
        return;
      }

      // Reset recover count
      if (posSec > 100) _adSkipRecoverCount = 0;

      // Lưu vị trí known
      if (posSec > _lastKnownPosition) _lastKnownPosition = posSec;

      // ★ REALTIME HOST SYNC: gửi position mỗi 1s khi đang play
      if (_isHost && _isPlaying) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - _lastHostSyncMs > 1000) {
          _lastHostSyncMs = nowMs;
          _updateHostState('playing');
        }
      }

      // Throttle UI
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastPositionUpdate > 500) {
        _lastPositionUpdate = now;
        setState(() {});
      }
    });

    _player!.stream.duration.listen((dur) {
      if (mounted) setState(() {});
    });

    _player!.stream.buffering.listen((buffering) {
      if (!buffering && mounted) {
        setState(() => _isPlayerReady = true);
      }
    });

    _player!.stream.completed.listen((completed) {
      if (completed && mounted) {
        setState(() => _videoState = 'paused');
      }
    });

    setState(() => _isLoading = false);
  }

  /// Bắt đầu timer lưu thời lượng mỗi 5 giây
  void _startWatchtimeSave() {
    _watchtimeSaveTimer?.cancel();
    _watchtimeSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        await _saveWatchtime();
      } catch (_) {}
    });
  }

  // ★ Fix A: Stuck detector
  void _startStuckDetector() {
    _stuckDetector?.cancel();
    _stuckTickCount = 0;
    _lastPositionForStuckCheck = 0;
    _stuckDetector = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || _player == null) return;
      final pos = _player!.state.position.inSeconds;
      final playing = _player!.state.playing;
      if (playing && pos > 0 && pos == _lastPositionForStuckCheck) {
        _stuckTickCount++;
        if (_stuckTickCount >= 3) {
          _stuckTickCount = 0;
          _player!.play();
          Future.delayed(const Duration(seconds: 2), () {
            if (!mounted || _player == null) return;
            final newPos = _player!.state.position.inSeconds;
            if (playing && newPos == pos) {
              _player!.seek(Duration(seconds: pos + 1));
              Future.delayed(const Duration(milliseconds: 500), () {
                if (mounted) _player?.play();
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

  // ★ Fix B: State sync
  void _startStateSync() {
    _stateSyncTimer?.cancel();
    _stateSyncTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _player == null) return;
      final actualPlaying = _player!.state.playing;
      if (_isPlaying != actualPlaying && mounted) {
        setState(() => _isPlaying = actualPlaying);
      }
      if (actualPlaying && !_isDragging) {
        final actualPos = _player!.state.position;
        if (actualPos.inSeconds > 0) {
          _lastKnownPosition = actualPos.inSeconds.toDouble();
        }
      }
    });
  }

  /// Lưu thời lượng hiện tại — cả local + server (watch history)
  Future<void> _saveWatchtime() async {
    if (_player == null) return;
    final pos = _player!.state.position.inSeconds;
    final dur = _player!.state.duration.inSeconds;
    if (pos > 0) {
      _lastSavedPosition = pos.toDouble();
    }
    // Lưu vào watch_history như xem phim bình thường
    if (_movieId > 0 && _episodeId > 0 && pos >= 5) {
      final ok = await _movieService.saveWatchProgress(
        movieId: _movieId,
        episodeId: _episodeId,
        epSlug: _epSlug,
        serverIdx: _selectedServer,
        position: pos,
        duration: dur > 0 ? dur : 0,
        sourceType: _sourceType.isNotEmpty ? _sourceType.toLowerCase() : 'hls',
        sourceUrl: '',
      );
    }
  }

  /// Load video source (m3u8)
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _bufferingSub;

  Future<void> _loadVideoSource(String m3u8Url) async {
    if (_player == null) return;

    try {
      setState(() => _isLoading = true);

      // Hủy listener cũ nếu có
      _durationSub?.cancel();
      _bufferingSub?.cancel();

      await _player!.open(
        Media(
          m3u8Url,
          httpHeaders: {
            'Referer': AppConfig.baseUrl,
            'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
          },
        ),
      );

      setState(() {
        _isLoading = false;
        _isPlaying = false;
      });

      // Đợi video load xong (duration > 0) rồi mới seek — iOS cần thời gian buffer
      final seekTo = widget.initialPosition > 3
          ? widget.initialPosition
          : (_lastSavedPosition > 3 ? _lastSavedPosition.toInt() : 0);

      if (seekTo > 3) {
        _initialSyncDone = true;
        // Đợi duration > 0 (video đã load đủ data để seek)
        _durationSub = _player!.stream.duration.distinct().listen((dur) {
          if (dur.inSeconds > 0 && mounted) {
            _durationSub?.cancel();
            _isPlayerReady = true;
            _seekWhenReady(seekTo.toDouble());
          }
        });
        // Fallback: nếu sau 5s vẫn chưa có duration → seek anyway
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted && !_isPlayerReady) {
            _durationSub?.cancel();
            _isPlayerReady = true;
            _seekWhenReady(seekTo.toDouble());
          }
        });
      } else {
        _isPlayerReady = true;
        // ★ host auto-play khi video load xong (không cần seek)
        if (_isHost) {
          _player!.play();
          _updateHostState('playing');
        }
      }

    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Không thể tải video';
      });
    }
  }

  void _setLocalAction() {
    _isLocalAction = true;
    _localActionTimer?.cancel();
    _localActionTimer = Timer(const Duration(milliseconds: 1200), () {
      _isLocalAction = false;
    });
  }

  // ── Video Sync ─────────────────────────────────────────

  /// ★ AD: KHÔNG can thiệp player — cùng HLS stream với web,
  /// player play xuyên ad, sync position bình thường.

  /// Mobile position → web position
  /// Mobile skip 30s ad → mobile position bị lệch +30s so với web
  /// Mobile 930s = Web 960s (mobile đã chạy 30s post-ad, web mới bắt đầu)
  /// → CỘNG 30s để convert sang web timeline
  double _mobileToWebTimeline(double localSeconds) {
    if (localSeconds > _adPosition + _adDuration) {
      return localSeconds + _adDuration; // 930 → 960, 960 → 990
    }
    return localSeconds;
  }

  /// Web position → mobile position (guest mobile only)
  /// Web 960s = Mobile 930s
  /// → Subtract 30s để convert sang mobile timeline
  double _webToMobileTimeline(double webSeconds) {
    if (webSeconds > _adPosition + _adDuration) {
      return webSeconds - _adDuration; // 960 → 930, 990 → 960
    }
    return webSeconds;
  }

  bool get _isAdSyncPaused => false; // Luôn sync — play xuyên ad

  Future<void> _updateHostState(String state, {double? position}) async {
    if (!_isHost) return;
    if (_isAdSyncPaused) return;
    _videoState = state;
    final localTime =
        position ?? (_player?.state.position.inSeconds.toDouble() ?? 0);
    _videoTime = _mobileToWebTimeline(localTime);
    final videoDuration = _player?.state.duration.inSeconds.toDouble() ?? 0;
    await _service.updateState(
      roomCode: widget.roomCode,
      videoTime: _videoTime,
      videoState: state,
      videoDuration: videoDuration,
    );
  }

  void _applyServerState(Map<String, dynamic> data) {
    if (_isHost) return;

    final newState = data['video_state']?.toString() ?? 'paused';
    final newTime = (data['video_time'] as num?)?.toDouble() ?? 0;
    final newEpisodeId = data['episode_id'] as int?;

    // Room ended
    if (data['status'] == 'ended') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phòng xem chung đã kết thúc!'), backgroundColor: Colors.redAccent),
      );
      Navigator.pop(context);
      return;
    }

    // Host vắng mặt — chỉ hiện cho GUEST
    if (!_isHost && data['status'] == 'waiting') {
      if (!_waitingHostShown) {
        _waitingHostShown = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chủ phòng tạm vắng, vui lòng chờ...'), backgroundColor: Colors.orange, duration: Duration(seconds: 3)),
        );
      }
    } else {
      _waitingHostShown = false;
    }

    // Episode changed — chỉ thông báo, KHÔNG return sớm
    // (tránh block update server health phía dưới)
    if (newEpisodeId != null && newEpisodeId != _episodeId && _episodeId > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chủ phòng đang chuyển tập...'), backgroundColor: Colors.orange),
      );
    }

    // Convert web timeline → mobile timeline
    final mobileTime = _webToMobileTimeline(newTime);

    setState(() {
      _videoState = newState;
      _videoTime = newTime; // giữ web time để display
    });

    if (_player == null) return;

    // ── Initial sync: seek đến vị trí host lần đầu ──
    if (!_initialSyncDone && newTime > 3) {
      _initialSyncDone = true;
      _seekWhenReady(mobileTime);
      return;
    }

    // ── Playing ──
    if (newState == 'playing') {
      final diff = (_player!.state.position.inSeconds - mobileTime).abs();
      if (diff > 4) {
        _seekWhenReady(mobileTime);
      } else if (!_player!.state.playing) {
        _setLocalAction();
        _player!.play();
      }
    } else {
      // ── Paused ──
      if (_player!.state.playing) {
        _setLocalAction();
        _player!.pause();
      }
      final diff = (_player!.state.position.inSeconds - mobileTime).abs();
      if (diff > 1) {
        _setLocalAction();
        _player!.seek(Duration(seconds: mobileTime.toInt()));
      }
    }
  }

  /// Seek an toàn: pause → mute → seek → đợi sync → restore volume → play
  /// ★ KEYFRAME FIX: seek +0.5s để media_kit align keyframe đúng/qua target
  void _seekWhenReady(double targetTime) {
    if (_player == null || targetTime <= 2) return;

    _seekRetryTimer?.cancel();
    _setLocalAction();

    // Pause + mute tạm thời
    if (_player!.state.playing) {
      _player!.pause();
    }
    _player!.setVolume(0);

    // Fallback: restore volume sau 3s nếu seek callback fail
    _seekRetryTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _player != null) {
        _player!.setVolume(_isMuted ? 0.0 : (_volume > 0 ? _volume : 100.0));
      }
    });

    // Seek — +0.5s offset để tránh keyframe trễ
    _player!.seek(Duration(milliseconds: (targetTime * 1000 + 500).toInt())).then((_) {
      _seekRetryTimer?.cancel();
      // Đợi 300ms (giảm từ 800ms)
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted || _player == null) return;
        final actual = _player!.state.position.inSeconds;
        final diff = (actual - targetTime).abs();
        if (diff > 5) {
          _player!.seek(Duration(milliseconds: (targetTime * 1000 + 500).toInt()));
        }
        // Restore volume + play
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted && _player != null) {
            _player!.setVolume(_isMuted ? 0.0 : (_volume > 0 ? _volume : 100.0));
            _player!.play();
            _setLocalAction();
            _updateHostState('playing');
          }
        });
      });
    });
  }

  // ── Polling ────────────────────────────────────────────

  /// Host sync video_time mỗi 1s
  void _startHostSync() {
    _hostSyncTimer?.cancel();
    _hostSyncTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isHost && _isPlaying && _player != null) {
        _updateHostState('playing');
      }
    });
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _poll());
    _poll(); // First poll immediately
  }

  Future<void> _poll() async {
    if (_isPolling) return;
    _isPolling = true;

    try {
      final data = await _service.ping(
        roomCode: widget.roomCode,
        lastMsgId: _lastMsgId,
        inVoice: _voiceService?.isJoined ?? false,
        isMuted: _voiceService?.isMuted ?? true,
        isSpeaking: _voiceService?.isSpeaking ?? false,
      );

      if (data['success'] != true) {
        _isPolling = false;
        return;
      }

      // Update host status TRƯỚC khi apply state (tránh hiện "host vắng mặt" cho chính host)
      _isHost = data['is_host'] == true;
      _myName = data['my_name']?.toString() ?? '';
      _hasPassword = data['has_password'] == true;

      // ★ RE-ENTRY: lưu video_time từ server để _loadVideoSource seek sau
      if (!_initialSyncDone && !_isPlayerReady) {
        final serverTime = (data['video_time'] as num?)?.toDouble() ?? 0;
        if (serverTime > 3 && widget.initialPosition <= 3) {
          _lastSavedPosition = serverTime;
          _videoTime = serverTime;
        }
      }

      // Apply video state
      _applyServerState(data);

      // Update members — voice participants lên đầu
      final members = (data['members'] as List<dynamic>?) ?? [];
      setState(() {
        _members.clear();
        _members.addAll(members.map((m) => RoomMember.fromJson(m)));
        _members.sort((a, b) {
          // Host luôn đầu tiên
          if (a.isHost && !b.isHost) return -1;
          if (!a.isHost && b.isHost) return 1;
          // Voice participants lên tiếp
          if (a.inVoice && !b.inVoice) return -1;
          if (!a.inVoice && b.inVoice) return 1;
          return 0;
        });
        _onlineCount = _members.length;
      });

      // Update voice members — MERGE thay vì replace
      // (tránh xóa participant do WebRTC auto-add khi server chưa sync)
      final voiceMembers = (data['voice_members'] as List<dynamic>?) ?? [];
      setState(() {
        // Tạo map từ server data
        final serverNames = <String>{};
        for (final v in voiceMembers) {
          final p = VoiceParticipant.fromJson(v);
          serverNames.add(p.name);
          final idx = _voiceParticipants.indexWhere((x) => x.name == p.name);
          if (idx >= 0) {
            _voiceParticipants[idx] = p; // Update existing
          } else {
            _voiceParticipants.add(p); // Add new từ server
          }
        }
        // Xóa participant không còn trong server VÀ không có WebRTC peer connected
        _voiceParticipants.removeWhere((p) =>
          !serverNames.contains(p.name) &&
          !(_voiceService?.isPeerConnected(p.name) ?? false)
        );
      });

      // Update chat messages
      final messages = (data['messages'] as List<dynamic>?) ?? [];
      if (messages.isNotEmpty) {
        int newCount = 0;
        setState(() {
          for (final msg in messages) {
            final chatMsg = ChatMessage.fromJson(msg);
            if (!_messages.any((m) => m.id == chatMsg.id)) {
              _messages.add(chatMsg);
              _lastMsgId = chatMsg.id;
              newCount++;
            }
          }
        });
        // Đếm tin nhắn chưa đọc khi chat ẩn trong fullscreen
        if (!_showChatInFullscreen && newCount > 0) {
          _unreadMessages += newCount;
        }
        _scrollToBottom();
      }

      // Update movie info + load video source
      if (data['movie_name'] != null) {
        final movieName = data['movie_name']?.toString() ?? '';
        final m3u8Url = data['m3u8_url']?.toString() ?? '';
        final epName = data['ep_name']?.toString() ?? '';
        final sourceType = data['source_type']?.toString() ?? '';

        setState(() {
          _movieName = movieName;
          _epName = epName;
          _movieId = data['movie_id'] as int? ?? 0;
          _episodeId = data['episode_id'] as int? ?? 0;
          _epSlug = data['ep_slug']?.toString() ?? '';
          _sourceType = sourceType;
          // Auto-select server dựa trên server_name
          final serverName = data['server_name']?.toString() ?? '';
          if (serverName.isNotEmpty && _servers.isNotEmpty) {
            final idx = _servers.indexWhere((s) => s['server_name'] == serverName);
            if (idx >= 0) _selectedServer = idx;
          }
        });

        // Load video source nếu có m3u8 và chưa load
        if (m3u8Url.isNotEmpty && _player != null && !_isPlayerReady) {
          _loadVideoSource(m3u8Url);
        }
      }

      // Update servers + episodes
      final servers = data['servers'];
      if (servers is Map<String, dynamic>) {
        setState(() {
          _servers = servers.entries.map((e) => {
            'server_name': e.key,
            'episodes': e.value,
          }).toList();
        });
      }

      // Không check server health — tất cả nguồn đều sống (mobile HLS chạy được hết)
    } catch (e) {
    }

    _isPolling = false;
  }

  // ── Chat ───────────────────────────────────────────────

  Future<void> _sendMessage() async {
    final msg = _chatController.text.trim();
    if (msg.isEmpty) return;
    _chatController.clear();

    await _service.sendChat(
      roomCode: widget.roomCode,
      message: msg,
    );
  }

  void _scrollToBottom() {
    if (_chatScrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }
  }

  // ── Voice ──────────────────────────────────────────────

  bool _isVoiceJoining = false; // Guard: chống bấm join nhiều lần

  Future<void> _toggleVoice() async {
    if (_voiceService?.isJoined ?? false) {
      // Leave — không cần guard, chỉ 1 lần
      _isVoiceJoining = false;
      await _voiceService?.leave();
      setState(() {});
    } else {
      // Guard: đang join rồi → bỏ qua, không tạo VoiceService mới
      if (_isVoiceJoining) return;
      _isVoiceJoining = true;

      // Đợi _myName có từ server trước khi join voice (tối đa 5s)
      if (_myName.isEmpty) {
        for (int i = 0; i < 10; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (_myName.isNotEmpty) break;
        }
      }
      final name = _myName.isNotEmpty ? _myName : 'Khách';
      _voiceService = VoiceService(
        roomCode: widget.roomCode,
        userName: name,
        onVoiceMembersUpdated: (members) {
          setState(() {
            _voiceParticipants.clear();
            _voiceParticipants.addAll(members.map((v) => VoiceParticipant.fromJson(v)));
          });
        },
        onStateChanged: () => setState(() {}),
        onParticipantsChanged: (_) => setState(() {}),
        onPollCompleted: () {
          if (mounted) setState(() {});
        },
        onDebugLog: (msg) {},
        onSpeakerToggled: (isSpeaker) {
          if (isSpeaker && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('💡 Dùng tai nghe để tránh echo/vọng'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 3),
              ),
            );
          }
        },
        onMicToggled: (isMuted) {
          // Khi tắt mic → đổi audio mode về bình thường + restore video volume
          if (isMuted) {
            const MethodChannel('phimhay_app/audio').invokeMethod('activateAudioSession');
            // Restore video volume sau khi audio mode đổi
            Future.delayed(const Duration(milliseconds: 300), () {
              if (mounted && _player != null) {
                final vol = _isMuted ? 0.0 : (_volume > 0 ? _volume : 100.0);
                _player!.setVolume(vol);
              }
            });
          } else {
            // Bật mic → re-apply voice audio session
            const MethodChannel('phimhay_app/audio').invokeMethod('configAVSession');
          }
        },
      );
      // Pass voice members từ room sync (server signaling có thể đã hết hạn cho user cũ)
      final knownVoiceMembers = _voiceParticipants
          .where((p) => p.name != _myName)
          .map((p) => p.name)
          .toList();
      final success = await _voiceService!.join(roomVoiceMembers: knownVoiceMembers);
      _isVoiceJoining = false; // Reset guard sau khi join xong

      // Restore video volume — audio mode change có thể đã giảm volume
      if (success && mounted && _player != null) {
        final vol = _isMuted ? 0.0 : (_volume > 0 ? _volume : 100.0);
        _player!.setVolume(vol);
      }

      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không thể tham gia voice. Vui lòng cấp quyền micro trong cài đặt.'), backgroundColor: Colors.redAccent),
        );
      }
      setState(() {});
    }
  }

  void _toggleMic() {
    _voiceService?.toggleMic();
    // Video volume restore được xử lý trong onMicToggled callback
  }

  // ── Build ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;

    // Device xoay ngang → tự fullscreen (không lock orientation)
    if (orientation == Orientation.landscape && !_isFullscreen) {
      _isFullscreen = true;
      _forcePortrait = false;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    // Device xoay dọc → tự thoát fullscreen
    if (orientation == Orientation.portrait && _isFullscreen && !_forcePortrait) {
      _isFullscreen = false;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }

    final isLandscape = orientation == Orientation.landscape || _isFullscreen;

    return Scaffold(
      backgroundColor: isLandscape ? Colors.black : AppTheme.bg,
      body: SafeArea(
        top: !isLandscape,
        child: isLandscape
            ? _buildLandscapeLayout()
            : _buildPortraitLayout(),
      ),
    );
  }

  Widget _buildPortraitLayout() {
    return Column(
      children: [
        // Header
        _buildHeader(),
        // Player
        _buildPlayer(),
        // Voice panel — luôn hiện (giống web)
        _buildVoicePanel(),
        // Tabs
        _buildTabs(),
        // Content
        Expanded(
          child: _selectedTab == 0 ? _buildChatTab() : _buildInfoTab(),
        ),
        // Chat input
        if (_selectedTab == 0) _buildChatInput(),
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    // Y HỆT video phim chi tiết: Stack + Positioned.fill(_buildPlayer())
    // Scaffold.backgroundColor = Colors.black → nền đen full màn hình
    return Stack(children: [
      // Video fill toàn bộ màn hình (giống video phim)
      Positioned.fill(child: _buildPlayer()),

      // Back button (góc trái trên) — về portrait
      Positioned(
        top: 8, left: 8,
        child: GestureDetector(
          onTap: _toggleFullscreen,
          child: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
            child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 22),
          ),
        ),
      ),

      // Right side buttons (chat + episode)
      Positioned(
        top: 0, bottom: 0, right: 12,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Episode selector button
            if (_servers.isNotEmpty)
              GestureDetector(
                onTap: () => setState(() => _showEpPanel = !_showEpPanel),
                child: Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: _showEpPanel
                        ? AppTheme.accent.withValues(alpha: 0.8)
                        : Colors.black54,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.playlist_play_rounded, color: Colors.white, size: 20),
                      if (_epName.isNotEmpty)
                        Text(
                          _epName,
                          style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            // Chat button
            GestureDetector(
              onTap: () => setState(() {
                _showChatInFullscreen = !_showChatInFullscreen;
                if (_showChatInFullscreen) _unreadMessages = 0;
              }),
              child: Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: _showChatInFullscreen
                      ? AppTheme.accent.withValues(alpha: 0.8)
                      : Colors.black54,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Center(child: Icon(Icons.chat_rounded, color: Colors.white, size: 24)),
                    if (_unreadMessages > 0 && !_showChatInFullscreen)
                      Positioned(
                        top: 0, right: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(10)),
                          constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                          child: Text(
                            _unreadMessages > 99 ? '99+' : '$_unreadMessages',
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),

      // Episode panel — overlay bên phải
      if (_showEpPanel)
        Positioned(
          top: 0, bottom: 0, right: 0,
          child: Container(
            width: 300,
            decoration: BoxDecoration(
              color: AppTheme.bg.withValues(alpha: 0.95),
              border: Border(left: BorderSide(color: AppTheme.border)),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
                  child: Row(
                    children: [
                      Icon(Icons.playlist_play_rounded, size: 16, color: AppTheme.accent),
                      const SizedBox(width: 8),
                      Text('Chọn tập', style: TextStyle(color: AppTheme.accent, fontSize: 13, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => setState(() => _showEpPanel = false),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Icon(Icons.close_rounded, size: 16, color: AppTheme.textMuted),
                        ),
                      ),
                    ],
                  ),
                ),
                // Server tabs
                if (_servers.length > 1)
                  SizedBox(
                    height: 44,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      itemCount: _servers.length,
                      itemBuilder: (ctx, i) {
                        final s = _servers[i];
                        final isActive = i == _selectedServer;
                        return GestureDetector(
                          onTap: () => setState(() => _selectedServer = i),
                          child: Container(
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: isActive ? AppTheme.accent.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: isActive ? AppTheme.accent : Colors.white24),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(width: 6, height: 6, decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle)),
                                const SizedBox(width: 4),
                                Text(
                                  s['server_name']?.toString() ?? 'Server ${i + 1}',
                                  style: TextStyle(color: isActive ? AppTheme.accent : Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                // Episode grid
                Expanded(
                  child: Builder(
                    builder: (ctx) {
                      final eps = _servers.isNotEmpty && _selectedServer < _servers.length
                          ? (_servers[_selectedServer]['episodes'] as List<dynamic>? ?? [])
                          : _episodes;
                      return GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 120,
                          mainAxisExtent: 36,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                        ),
                        itemCount: eps.length,
                        itemBuilder: (ctx, i) {
                          final ep = eps[i];
                          final epId = ep['id'] ?? 0;
                          final isActive = epId == _episodeId;
                          final name = (ep['ep_name'] ?? 'Tập ${i + 1}').toString();
                          return GestureDetector(
                            onTap: () {
                              // Host có thể chuyển tập, guest chỉ xem
                              if (_isHost) {
                                _switchEpisode(epId);
                                setState(() => _showEpPanel = false);
                              }
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                color: isActive ? AppTheme.accent.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.04),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: isActive ? AppTheme.accent : Colors.white24),
                              ),
                              child: Center(
                                child: Text(
                                  name,
                                  style: TextStyle(
                                    color: isActive ? AppTheme.accent : Colors.white70,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),

      // Chat panel — overlay bên phải
      if (_showChatInFullscreen)
        Positioned(
          top: 0, bottom: 0, right: 0,
          child: Container(
            width: 300,
            decoration: BoxDecoration(
              color: AppTheme.bg.withValues(alpha: 0.95),
              border: Border(left: BorderSide(color: AppTheme.border)),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
                  child: Row(
                    children: [
                      Icon(Icons.chat_rounded, size: 16, color: AppTheme.accent),
                      const SizedBox(width: 8),
                      Text('Trò chuyện', style: TextStyle(color: AppTheme.accent, fontSize: 13, fontWeight: FontWeight.w700)),
                      Text(' (${_messages.length})', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => setState(() => _showChatInFullscreen = false),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Icon(Icons.close_rounded, size: 16, color: AppTheme.textMuted),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: _buildChatTab()),
                _buildChatInput(),
              ],
            ),
          ),
        ),
    ]);
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _movieName.isNotEmpty ? _movieName : 'Phòng xem chung',
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Row(
                  children: [
                    if (_epName.isNotEmpty) ...[
                      Text(
                        _epName.toLowerCase().startsWith('tập') ? _epName : 'Tập $_epName',
                        style: TextStyle(color: AppTheme.accent, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                      Text(' • ', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                    ],
                    Text(
                      '${_isHost ? "Chủ phòng" : (_myName.isNotEmpty ? _myName : "Khách")} • Online: $_onlineCount',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Password button (host only)
          if (_isHost) ...[
            GestureDetector(
              onTap: _showPasswordManageDialog,
              onLongPress: _hasPassword ? _showPasswordManageDialog : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _hasPassword
                      ? const Color(0x26fb923c)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _hasPassword
                        ? const Color(0x4Dfb923c)
                        : AppTheme.border,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _hasPassword ? Icons.lock : Icons.lock_open,
                      size: 16,
                      color: _hasPassword ? const Color(0xFFfb923c) : AppTheme.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _hasPassword ? '••••' : 'Mật khẩu',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _hasPassword ? const Color(0xFFfb923c) : AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          // Share button
          GestureDetector(
            onTap: () => _showSharePopup(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.accent.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.share_rounded, size: 16, color: AppTheme.accent),
                  const SizedBox(width: 4),
                  Text('Chia sẻ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.accent)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayer() {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
          color: Colors.black,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Video (không hiện controls mặc định)
              if (_videoController != null && _isPlayerReady)
                Video(
                  controller: _videoController!,
                  controls: NoVideoControls, // Bỏ controls mặc định
                ),
              // Loading
              if (_isLoading)
                const CircularProgressIndicator(color: AppTheme.accent),
              // Error
              if (_error != null)
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline, size: 48, color: Colors.white38),
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(color: Colors.white54, fontSize: 14)),
                  ],
                ),
              // Guest overlay: chủ phòng đã dừng video
              if (!_isHost && _videoState == 'paused' && !_isLoading && _initialSyncDone)
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.pause_rounded, size: 36, color: Colors.white),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Chủ phòng đã tạm dừng',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              // Gesture zones: trái (tap+double-tap = lùi 10s), giữa (tap = toggle), phải (tap+double-tap = tới 10s)
              if (_isPlayerReady)
                Row(
                  children: [
                    // LEFT zone: tap = toggle controls, double-tap = lùi 10s
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () {
                          setState(() => _showControls = !_showControls);
                          if (_showControls) _autoHideControls();
                        },
                        onDoubleTap: () {
                          final pos = _player?.state.position ?? Duration.zero;
                          final newPos = Duration(seconds: max(0, pos.inSeconds - 10));
                          _setLocalAction();
  

                          _player?.seek(newPos);
                          _updateHostState(_videoState, position: newPos.inSeconds.toDouble());
                          _saveWatchtime();
                        },
                        child: const SizedBox.expand(),
                      ),
                    ),
                    // CENTER zone
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () {
                          setState(() => _showControls = !_showControls);
                          if (_showControls) _autoHideControls();
                        },
                        child: const SizedBox.expand(),
                      ),
                    ),
                    // RIGHT zone
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () {
                          setState(() => _showControls = !_showControls);
                          if (_showControls) _autoHideControls();
                        },
                        onDoubleTap: () {
                          final pos = _player?.state.position ?? Duration.zero;
                          final newPos = pos + const Duration(seconds: 10);
                          _setLocalAction();
  

                          _player?.seek(newPos);
                          _updateHostState(_videoState, position: newPos.inSeconds.toDouble());
                          _saveWatchtime();
                        },
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
              // Host controls overlay — nút rewind/play/forward
              if (_isHost && _showControls && _isPlayerReady) ...[
                // Rewind/Forward icons — căn giữa mỗi nửa video (tappable)
                Row(
                  children: [
                    Expanded(
                      child: Center(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            final pos = _player?.state.position ?? Duration.zero;
                            final newPos = Duration(seconds: max(0, pos.inSeconds - 10));
                            _setLocalAction();
    

                            _player?.seek(newPos);
                            _updateHostState(_videoState, position: newPos.inSeconds.toDouble());
                            _saveWatchtime();
                          },
                          child: Container(
                            width: 56, height: 56,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.replay_10_rounded, color: Colors.white, size: 28),
                          ),
                        ),
                      ),
                    ),
                    const Expanded(child: SizedBox()),
                    Expanded(
                      child: Center(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            final pos = _player?.state.position ?? Duration.zero;
                            final newPos = pos + const Duration(seconds: 10);
                            _setLocalAction();
    

                            _player?.seek(newPos);
                            _updateHostState(_videoState, position: newPos.inSeconds.toDouble());
                            _saveWatchtime();
                          },
                          child: Container(
                            width: 56, height: 56,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.forward_10_rounded, color: Colors.white, size: 28),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // Play/Pause ở giữa
                Center(child: _buildHostControls()),
              ],
              // Tên phim + tập (top left, sau back button khi fullscreen)
              if (_isFullscreen)
                Positioned(
                  top: 8,
                  left: 56,
                  child: _buildMovieInfoOverlay(),
                ),
              // Sync indicator (guest - playing) — đặt dưới đồng hồ
              if (!_isHost && _videoState == 'playing')
                Positioned(
                  top: 40,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'LIVE',
                          style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  ),
                ),
              // Bottom bar: time + speed + timeline — ẩn/hiện theo tap
              if (_showControls)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _buildBottomBar(),
                ),
              // ── Đồng hồ VN góc phải trên — chỉ hiện khi fullscreen ──
              if (_isFullscreen)
                Positioned(
                  top: 8, right: 8,
                  child: _buildClockWidget(),
                ),
            ],
          ),
        ),
    );
  }

  void _autoHideControls() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  /// Tên phim + tập — luôn hiện góc trái trên video
  Widget _buildMovieInfoOverlay() {
    final movieName = _movieName;
    final rawEp = _epName;
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

  /// Đồng hồ giờ VN — luôn hiện ở góc phải trên video
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

  Widget _buildHostControls() {
    // Chỉ còn play/pause ở giữa, rewind/forward đã ra 2 bên
    return GestureDetector(
      onTap: () {
        _setLocalAction();
        if (_player!.state.playing) {
          _player!.pause();
          _updateHostState('paused');
        } else {
          _player!.play();
          _updateHostState('playing');
        }
      },
      child: Container(
        width: 56, height: 56,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 2),
        ),
        child: Icon(
          _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: Colors.white, size: 34,
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final position = _player?.state.position ?? Duration.zero;
    final duration = _player?.state.duration ?? Duration.zero;
    final progress = duration.inSeconds > 0 ? position.inSeconds / duration.inSeconds : 0.0;
    // Dùng giá trị drag khi đang kéo,否则 dùng progress thực
    final displayValue = _isDragging ? _dragValue : progress;

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
          // Timeline bar
          if (_isPlayerReady)
            SliderTheme(
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
                onChangeStart: _isHost
                    ? (value) {
                        _isDragging = true;
                        _dragValue = value;
                      }
                    : null,
                onChanged: _isHost
                    ? (value) {
                        _dragValue = value;
                        // Không seek liên tục khi kéo — chỉ update UI
                        setState(() {});
                      }
                    : null,
                onChangeEnd: _isHost
                    ? (value) {
                        _isDragging = false;
                        final newPos = Duration(seconds: (value * duration.inSeconds).toInt());
                        _setLocalAction();


                        _player?.seek(newPos);
                        _updateHostState(_videoState, position: newPos.inSeconds.toDouble());
                        _saveWatchtime();
                      }
                    : null,
              ),
            ),
          // Time + Speed
          Row(
            children: [
              Text(
                _formatDuration(_isDragging ? Duration(seconds: (_dragValue * duration.inSeconds).toInt()) : position),
                style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'),
              ),
              Text(
                ' / ${_formatDuration(duration)}',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11, fontFamily: 'monospace'),
              ),
              const Spacer(),
              // Speed control
              GestureDetector(
                onTap: _cycleSpeed,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _playbackSpeed != 1.0
                        ? AppTheme.accent.withValues(alpha: 0.8)
                        : Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'x$_playbackSpeed',
                    style: TextStyle(
                      color: _playbackSpeed != 1.0 ? Colors.black : Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Volume — tap icon → expand inline slider, long press → mute
              GestureDetector(
                onLongPress: _toggleMute,
                onTap: () => setState(() => _showVolumeInline = !_showVolumeInline),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isMuted || _volume == 0
                            ? Icons.volume_off_rounded
                            : _volume < 50
                                ? Icons.volume_down_rounded
                                : Icons.volume_up_rounded,
                        color: _isMuted || _volume == 0 ? Colors.redAccent : Colors.white,
                        size: 16,
                      ),
                      // Inline slider — hiện khi tap
                      if (_showVolumeInline) ...[
                        const SizedBox(width: 6),
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
                        SizedBox(
                          width: 24,
                          child: Text(
                            '${_volume.round()}',
                            style: TextStyle(
                              color: _volume <= 0 ? Colors.redAccent : Colors.white70,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Fullscreen toggle
              GestureDetector(
                onTap: _toggleFullscreen,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    _isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                    color: Colors.white,
                    size: 18,
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

    // Auto reset to x1 when caught up with host
    if (_playbackSpeed > 1.0) {
      _checkSpeedReset();
    }
  }

  void _checkSpeedReset() {
    // Check periodically if guest caught up with host
    Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted || _playbackSpeed <= 1.0) {
        timer.cancel();
        return;
      }
      final diff = _videoTime - (_player?.state.position.inSeconds.toDouble() ?? 0);
      if (diff <= 1.0) {
        setState(() {
          _playbackSpeed = 1.0;
          _player?.setRate(1.0);
        });
        timer.cancel();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã bắt kịp, tốc độ về x1'), backgroundColor: Colors.green),
        );
      }
    });
  }

  void _toggleFullscreen() {
    setState(() {
      _isFullscreen = !_isFullscreen;
      _forcePortrait = !_isFullscreen;
    });
    if (_isFullscreen) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      _restoreOrientations();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _toggleMute() {
    final currentVol = _player?.state.volume ?? 100.0;
    if (currentVol > 0) {
      // Đang có âm → mute + lưu volume cũ
      _volume = currentVol;
      _isMuted = true;
      _player?.setVolume(0.0);
    } else {
      // Đang mute → unmute
      _isMuted = false;
      _player?.setVolume(_volume > 0 ? _volume : 100.0);
    }
    setState(() {});
  }

  void _showSharePopup() {
    final shareUrl = '${AppConfig.baseUrl}/phong-xem.php?code=${widget.roomCode}';
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Text('Chia sẻ phòng xem', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
            const SizedBox(height: 16),

            // QR Code
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: QrImageView(
                data: shareUrl,
                size: 160,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),

            // Link display
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(shareUrl, style: TextStyle(fontSize: 11, color: AppTheme.textSub), overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: shareUrl));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Đã sao chép liên kết!'), backgroundColor: Colors.green),
                      );
                    },
                    child: Icon(Icons.copy_rounded, size: 18, color: AppTheme.accent),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Copy link button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: shareUrl));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Đã sao chép liên kết!'), backgroundColor: Colors.green),
                  );
                  Navigator.pop(ctx);
                },
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('Sao chép liên kết'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showVolumeSlider() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'volume',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (ctx, _, __) => const SizedBox(),
      transitionBuilder: (ctx, anim, _, __) {
        return FadeTransition(
          opacity: anim,
          child: Stack(
            children: [
              // Tap outside để đóng
              GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(color: Colors.transparent),
              ),
              // Popup nổi ở góc phải dưới
              Positioned(
                bottom: 80,
                right: 16,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: 200,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E2026),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 20, offset: const Offset(0, 8)),
                      ],
                    ),
                    child: StatefulBuilder(
                      builder: (context, setDialogState) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _volume <= 0 ? Icons.volume_off_rounded
                                    : _volume < 50 ? Icons.volume_down_rounded
                                    : Icons.volume_up_rounded,
                                color: _volume <= 0 ? Colors.redAccent : AppTheme.accent,
                                size: 18,
                              ),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderThemeData(
                                    trackHeight: 3,
                                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                    activeTrackColor: AppTheme.accent,
                                    inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
                                    thumbColor: AppTheme.accent,
                                    overlayColor: AppTheme.accent.withValues(alpha: 0.15),
                                  ),
                                  child: Slider(
                                    value: _volume,
                                    min: 0,
                                    max: 100,
                                    divisions: 20,
                                    onChanged: (val) {
                                      setDialogState(() => _volume = val);
                                      setState(() {
                                        _isMuted = val == 0;
                                        _player?.setVolume(val);
                                      });
                                    },
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 32,
                                child: Text(
                                  '${_volume.round()}',
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    color: _volume <= 0 ? Colors.redAccent : Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildVoicePanel() {
    final isJoined = _voiceService?.isJoined ?? false;
    final connType = _voiceService?.connectionType ?? 'disconnected';
    final latency = _voiceService?.latencyMs ?? -1;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.05),
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Row(
            children: [
              Icon(Icons.mic_rounded, size: 16, color: Colors.greenAccent),
              const SizedBox(width: 8),
              Text('Voice Chat', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.w700)),
              Text(' (${_voiceParticipants.length})', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
              // Connection type badge: P2P/Relay + Ping
              if (isJoined && connType != 'disconnected') ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: connType == 'p2p'
                        ? Colors.green.withValues(alpha: 0.2)
                        : Colors.orange.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: connType == 'p2p'
                          ? Colors.green.withValues(alpha: 0.4)
                          : Colors.orange.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: connType == 'p2p' ? Colors.greenAccent : Colors.orangeAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        connType == 'p2p' ? 'P2P' : 'Relay',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: connType == 'p2p' ? Colors.greenAccent : Colors.orangeAccent,
                        ),
                      ),
                      // Ping display
                      if (latency >= 0) ...[
                        const SizedBox(width: 4),
                        Text(
                          '${latency}ms',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: latency < 100
                                ? Colors.greenAccent
                                : latency < 300
                                    ? Colors.orangeAccent
                                    : Colors.redAccent,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const Spacer(),
              if (isJoined) ...[
                // Tai nghe: mute/unmute toàn bộ remote audio
                GestureDetector(
                  onTap: () => _voiceService?.toggleSpeaker(),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: (_voiceService?.speakerMuted ?? false)
                          ? Colors.red.withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      (_voiceService?.speakerMuted ?? false)
                          ? Icons.headphones
                          : Icons.headphones_outlined,
                      size: 16,
                      color: (_voiceService?.speakerMuted ?? false)
                          ? Colors.redAccent
                          : Colors.greenAccent,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Loa: toggle earpiece ↔ speaker
                GestureDetector(
                  onTap: () => _voiceService?.toggleSpeakerOutput(),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: (_voiceService?.isSpeakerOutput ?? false)
                          ? Colors.blue.withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      (_voiceService?.isSpeakerOutput ?? false)
                          ? Icons.volume_up_rounded
                          : Icons.volume_down_rounded,
                      size: 16,
                      color: (_voiceService?.isSpeakerOutput ?? false)
                          ? Colors.blueAccent
                          : AppTheme.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Mic toggle
                GestureDetector(
                  onTap: _toggleMic,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: (_voiceService?.isMuted ?? true)
                          ? Colors.red.withValues(alpha: 0.2)
                          : Colors.green.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      (_voiceService?.isMuted ?? true) ? Icons.mic_off : Icons.mic,
                      size: 16,
                      color: (_voiceService?.isMuted ?? true) ? Colors.redAccent : Colors.greenAccent,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Leave
                GestureDetector(
                  onTap: _toggleVoice,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.call_end, size: 16, color: Colors.redAccent),
                  ),
                ),
              ] else ...[
                // Join button
                GestureDetector(
                  onTap: _toggleVoice,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.mic, size: 14, color: Colors.greenAccent),
                        const SizedBox(width: 4),
                        Text('Tham gia', style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          // Participants tiles — giữ vị trí cố định, chỉ hiện vòng sáng tại chỗ
          if (_voiceParticipants.isEmpty)
            Text('Chưa có ai trong voice', style: TextStyle(color: AppTheme.textMuted, fontSize: 11))
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _voiceParticipants.map((p) => _buildVoiceTile(p)).toList(),
              ),
            ),
          // Note hướng dẫn
          if (isJoined) ...[
            const SizedBox(height: 4),
            Text(
              'Lần đầu cấp quyền nếu mic không hoạt động, thoát phòng vào lại.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 9, fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVoiceTile(VoiceParticipant p) {
    final isUserMuted = _voiceService?.isUserMuted(p.name) ?? false;
    final isJoined = _voiceService?.isJoined ?? false;
    final speaking = p.isSpeaking;

    // Layout y hệt web: column (avatar trên, tên dưới), avatar 32px, border xanh khi nói
    final tile = Container(
      width: 48,
      margin: const EdgeInsets.only(right: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Avatar + mic badge (stack)
          Stack(
            clipBehavior: Clip.none,
            children: [
              // Avatar — 32px, border 2.5px, speaking → border #4ade80
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: speaking ? const Color(0xFF4ade80) : Colors.transparent,
                    width: 2.5,
                  ),
                ),
                child: CircleAvatar(
                  radius: 14,
                  backgroundColor: AppTheme.bgSurface,
                  backgroundImage: p.avatar.isNotEmpty ? NetworkImage(p.avatar) : null,
                  child: p.avatar.isEmpty
                      ? Text(
                          p.name.isNotEmpty ? p.name[0].toUpperCase() : '?',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
                        )
                      : null,
                ),
              ),
              // Mic badge — góc phải dưới avatar, chỉ hiện khi muted
              if (p.isMuted)
                Positioned(
                  bottom: -2,
                  right: -2,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: const Color(0xFFf5c518),
                      shape: BoxShape.circle,
                      border: Border.all(color: AppTheme.bg, width: 1.5),
                    ),
                    child: const Icon(Icons.mic_off, size: 9, color: Colors.white),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // Tên — max 48px, truncate, speaking → #4ade80
          SizedBox(
            width: 48,
            child: Text(
              p.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: speaking
                    ? const Color(0xFF4ade80)
                    : isUserMuted
                        ? AppTheme.textMuted
                        : AppTheme.textSub,
                decoration: isUserMuted ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );

    // Chỉ cho phép long-press khi đã join voice
    if (isJoined) {
      return GestureDetector(
        onLongPress: () => _showUserMutePopup(p.name),
        child: tile,
      );
    }
    return tile;
  }

  void _showUserMutePopup(String userName) {
    if (!(_voiceService?.isJoined ?? false)) return; // Chỉ hiện khi đã join voice

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        // Dùng local state cho slider — không đọc từ service mỗi lần build
        double sliderValue = _voiceService?.getUserVolume(userName) ?? 1.0;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isMuted = _voiceService?.isUserMuted(userName) ?? false;

            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.textMuted.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(userName, style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 16),
                  // Volume slider
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(Icons.volume_down, size: 20, color: AppTheme.textMuted),
                            Expanded(
                              child: SliderTheme(
                                data: SliderThemeData(
                                  trackHeight: 4,
                                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 8),
                                  activeTrackColor: AppTheme.accent,
                                  inactiveTrackColor: AppTheme.border,
                                  thumbColor: AppTheme.accent,
                                ),
                                child: Slider(
                                  value: sliderValue,
                                  min: 0.0,
                                  max: 2.0,
                                  divisions: 20,
                                  onChanged: (val) {
                                    setDialogState(() {
                                      sliderValue = val;
                                    });
                                    _voiceService?.setUserVolume(userName, val);
                                    if (val == 0 && !isMuted) {
                                      _voiceService?.toggleUserMute(userName);
                                    } else if (val > 0 && isMuted) {
                                      _voiceService?.toggleUserMute(userName);
                                    }
                                  },
                                ),
                              ),
                            ),
                            Icon(Icons.volume_up, size: 20, color: AppTheme.textMuted),
                          ],
                        ),
                        Text(
                          '${(sliderValue * 100).round()}%',
                          style: TextStyle(color: AppTheme.accent, fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Mute toggle
                  ListTile(
                    leading: Icon(
                      isMuted ? Icons.hearing : Icons.hearing_disabled,
                      color: isMuted ? Colors.greenAccent : Colors.redAccent,
                    ),
                    title: Text(
                      isMuted ? 'Bật nghe $userName' : 'Tắt nghe $userName',
                      style: TextStyle(color: AppTheme.textPrimary),
                    ),
                    onTap: () {
                      _voiceService?.toggleUserMute(userName);
                      Navigator.pop(ctx);
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showPasswordManageDialog() {
    final passwordController = TextEditingController();
    String? errorText;
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> savePassword() async {
            final password = passwordController.text.trim();
            if (password.isNotEmpty && password.length < 4) {
              setDialogState(() => errorText = 'Mật khẩu tối thiểu 4 ký tự');
              return;
            }

            setDialogState(() {
              errorText = null;
              isLoading = true;
            });

            final service = WatchPartyService();
            final result = await service.updatePassword(
              roomCode: widget.roomCode,
              password: password,
            );

            if (result['success'] == true) {
              if (mounted) {
                Navigator.pop(ctx);
                setState(() => _hasPassword = password.isNotEmpty);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(password.isEmpty ? 'Đã bỏ mật khẩu' : 'Đã cập nhật mật khẩu'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            } else {
              setDialogState(() {
                errorText = result['error']?.toString() ?? 'Lỗi cập nhật mật khẩu';
                isLoading = false;
              });
            }
          }

          return AlertDialog(
            backgroundColor: AppTheme.bgCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Icon(_hasPassword ? Icons.lock : Icons.lock_open, size: 20, color: const Color(0xFFfb923c)),
                const SizedBox(width: 8),
                Text(
                  _hasPassword ? 'Đổi mật khẩu' : 'Đặt mật khẩu',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_hasPassword) ...[
                  // Nút xóa password
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: isLoading
                          ? null
                          : () {
                              passwordController.text = '';
                              savePassword();
                            },
                      icon: Icon(Icons.lock_open, size: 16, color: Colors.redAccent),
                      label: Text('Bỏ mật khẩu', style: TextStyle(color: Colors.redAccent)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.3)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('hoặc đổi mật khẩu mới:', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                  const SizedBox(height: 8),
                ],
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  autofocus: !_hasPassword,
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Nhập mật khẩu mới (tối thiểu 4 ký tự)',
                    hintStyle: TextStyle(color: AppTheme.textMuted),
                    filled: true,
                    fillColor: AppTheme.bgSurface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppTheme.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppTheme.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppTheme.accent),
                    ),
                    errorText: errorText,
                    prefixIcon: Icon(Icons.key, size: 18, color: AppTheme.textMuted),
                  ),
                  onSubmitted: (_) => savePassword(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Hủy', style: TextStyle(color: AppTheme.textMuted)),
              ),
              ElevatedButton(
                onPressed: isLoading ? null : savePassword,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: isLoading
                    ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text('Lưu', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTabs() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          _buildTab('Trò chuyện', 0),
          _buildTab('Thông tin', 1),
        ],
      ),
    );
  }

  Widget _buildTab(String label, int index) {
    final isActive = _selectedTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isActive ? AppTheme.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isActive ? AppTheme.accent : AppTheme.textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChatTab() {
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 48, color: AppTheme.textMuted.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text('Chào mừng đến phòng xem chung!', style: TextStyle(color: AppTheme.textSub, fontSize: 14)),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _chatScrollController,
      padding: const EdgeInsets.all(12),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        return _buildChatMessage(msg);
      },
    );
  }

  Widget _buildChatMessage(ChatMessage msg) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar — hiện ảnh nếu có, fallback chữ cái đầu
          CircleAvatar(
            radius: 14,
            backgroundColor: msg.isHost ? AppTheme.accent : AppTheme.bgCard,
            backgroundImage: msg.avatar.isNotEmpty ? NetworkImage(msg.avatar) : null,
            child: msg.avatar.isEmpty
                ? Text(
                    msg.author.isNotEmpty ? msg.author[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: msg.isHost ? Colors.black : AppTheme.textPrimary,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 8),
          // Content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      msg.author,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: msg.isHost ? AppTheme.accent : AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(msg.time, style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
                  ],
                ),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: msg.isHost
                        ? AppTheme.accent.withValues(alpha: 0.08)
                        : AppTheme.bgCard,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: msg.isHost
                          ? AppTheme.accent.withValues(alpha: 0.2)
                          : AppTheme.border,
                    ),
                  ),
                  child: Text(
                    msg.message,
                    style: TextStyle(fontSize: 13, color: AppTheme.textPrimary, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Room info
          _buildInfoCard('Thông tin phòng', [
            _infoRow('Mã phòng', widget.roomCode),
            _infoRow('Phim', _movieName.isNotEmpty ? _movieName : 'Đang tải...'),
            if (_epName.isNotEmpty) _infoRow('Tập', _epName.toLowerCase().startsWith('tập') ? _epName : 'Tập $_epName'),
            if (_servers.isNotEmpty && _selectedServer < _servers.length)
              _infoRow('Server', _servers[_selectedServer]['server_name']?.toString() ?? ''),
            _infoRow('Nguồn', _sourceType.isNotEmpty
                ? '$_sourceType (${_isPlayerReady ? "Đã tải" : "Đang tải..."})'
                : 'Chưa có'),
            _infoRow('Trạng thái', _videoState == 'playing' ? 'Đang phát' : 'Tạm dừng'),
            _infoRow('Online', '$_onlineCount người'),
          ]),
          const SizedBox(height: 16),
          // Episodes (nếu có servers)
          if (_servers.isNotEmpty) ...[
            _buildEpisodeSection(),
            const SizedBox(height: 16),
          ],
          // Members
          _buildInfoCard('Đang xem (${_members.length})', _members.map((m) =>
            _memberRow(m.name, m.avatar, m.isHost, m.inVoice)
          ).toList()),
        ],
      ),
    );
  }

  Widget _buildEpisodeSection() {
    return Container(
      padding: const EdgeInsets.all(16),
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
              Text(
                'Danh sách tập',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
              ),
              if (_isHost) ...[
                const Spacer(),
                Text(
                  'Chủ phòng chọn tập',
                  style: TextStyle(color: AppTheme.accent, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          // Server tabs — tất cả nguồn đều sống
          if (_servers.length > 1) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _servers.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final server = entry.value;
                  final serverName = server['server_name']?.toString() ?? 'Server ${idx + 1}';
                  final isActive = idx == _selectedServer;

                  return GestureDetector(
                    onTap: () => setState(() => _selectedServer = idx),
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: isActive ? AppTheme.accent.withValues(alpha: 0.15) : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isActive ? AppTheme.accent : AppTheme.border,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Dot xanh — tất cả đều sống
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            serverName,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isActive ? AppTheme.accent : AppTheme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 12),
          ],
          // Episodes grid
          if (_servers.isNotEmpty && _selectedServer < _servers.length)
            _buildEpisodeGrid(_servers[_selectedServer]),
        ],
      ),
    );
  }

  Widget _buildEpisodeGrid(Map<String, dynamic> server) {
    final episodes = (server['episodes'] as List<dynamic>?) ?? [];
    final serverName = server['server_name']?.toString() ?? '';
    if (episodes.isEmpty) {
      return Text('Không có tập nào', style: TextStyle(color: AppTheme.textMuted, fontSize: 13));
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: episodes.map((ep) {
        final epId = ep['id'] as int? ?? 0;
        final epName = ep['ep_name']?.toString() ?? '';
        final isActive = epId == _episodeId;

        return GestureDetector(
          onTap: _isHost ? () => _switchEpisode(epId) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isActive ? Colors.white.withValues(alpha: 0.12) : AppTheme.bgSurface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isActive ? Colors.white.withValues(alpha: 0.3) : AppTheme.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  epName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isActive ? Colors.white : AppTheme.textPrimary,
                  ),
                ),
                if (isActive) ...[
                  const SizedBox(width: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Đang chiếu',
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.green),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Future<void> _switchEpisode(int episodeId) async {
    if (!_isHost) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: Text('Chuyển tập?', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('Bạn có chắc muốn chuyển tập này cho cả phòng?', style: TextStyle(color: AppTheme.textSub)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Hủy', style: TextStyle(color: AppTheme.textMuted))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Chuyển', style: TextStyle(color: AppTheme.accent))),
        ],
      ),
    );

    if (confirm != true) return;

    final success = await _service.switchEpisode(
      roomCode: widget.roomCode,
      episodeId: episodeId,
    );

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã chuyển tập'), backgroundColor: Colors.green),
      );
      // Reload
      setState(() {
        _episodeId = episodeId;
        _isPlayerReady = false;
        _initialSyncDone = false;
      });
    }
  }

  Widget _buildInfoCard(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
          ),
          Expanded(
            child: Text(value, style: TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  Widget _memberRow(String name, String avatar, bool isHost, bool inVoice) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          // Avatar
          CircleAvatar(
            radius: 14,
            backgroundColor: isHost ? AppTheme.accent : AppTheme.bgSurface,
            backgroundImage: avatar.isNotEmpty ? NetworkImage(avatar) : null,
            child: avatar.isEmpty
                ? Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isHost ? Colors.black : AppTheme.textPrimary,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                if (isHost)
                  Text('Chủ phòng', style: TextStyle(color: AppTheme.accent, fontSize: 10, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          if (inVoice)
            Icon(Icons.mic, size: 16, color: Colors.greenAccent),
        ],
      ),
    );
  }

  Widget _buildChatInput() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(top: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _chatController,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Gửi tin nhắn...',
                hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                filled: true,
                fillColor: AppTheme.bgSurface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppTheme.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppTheme.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppTheme.accent),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendMessage,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.accent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
