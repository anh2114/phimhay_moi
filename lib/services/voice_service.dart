import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'api_client.dart';

/// Voice Chat Service — WebRTC + PHP signaling (giống web phong-xem.php)
class VoiceService {
  final String roomCode;
  final String userName;
  final String userAvatar;
  final Function(List<dynamic>)? onVoiceMembersUpdated;
  final Function()? onStateChanged;
  final Function(Map<String, VoiceParticipantState>)? onParticipantsChanged;
  final Function(String)? onDebugLog;
  final Function()? onPollCompleted;
  final Function(bool)? onSpeakerToggled;
  final Function(bool)? onMicToggled;

  VoiceService({
    required this.roomCode,
    required this.userName,
    this.userAvatar = '',
    this.onVoiceMembersUpdated,
    this.onStateChanged,
    this.onParticipantsChanged,
    this.onDebugLog,
    this.onPollCompleted,
    this.onSpeakerToggled,
    this.onMicToggled,
  });

  void _log(String msg) {
    onDebugLog?.call(msg);
  }

  // ── State ────────────────────────────────────────────────
  bool _isJoined = false;
  bool _isMuted = true;
  bool _isSpeaking = false;
  bool _speakerMuted = false;
  bool _isJoining = false;
  bool _isLeaving = false;

  bool get isJoined => _isJoined;
  bool get isMuted => _isMuted;
  bool get isSpeaking => _isSpeaking;
  bool get speakerMuted => _speakerMuted;

  int get peerCount => _peers.length;

  /// Kiểm tra peer có đang connected qua WebRTC không
  bool isPeerConnected(String name) {
    final pc = _peers[name];
    if (pc == null) return false;
    return pc.iceConnectionState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
           pc.iceConnectionState == RTCIceConnectionState.RTCIceConnectionStateCompleted;
  }

  // Local audio
  MediaStream? _localStream;

  // Peer connections: userName → RTCPeerConnection
  final Map<String, RTCPeerConnection> _peers = {};

  // ICE candidate queues: userName → list of candidates waiting for remote description
  final Map<String, List<RTCIceCandidate>> _iceQueues = {};

  // Track which peers have remote description set
  final Set<String> _remoteDescSet = {};

  // Đang tạo offer cho peer (防止 duplicate)
  final Set<String> _creatingOfferFor = {};


  // Remote audio renderers: userName → RTCVideoRenderer (dùng cho audio)
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};

  // Participants state
  final Map<String, VoiceParticipantState> _participants = {};

  // Per-user mute
  final Set<String> _mutedUsers = {};

  // Per-user volume (0.0 - 2.0, default 1.0)
  final Map<String, double> _userVolumes = {};

  double getUserVolume(String targetUser) => _userVolumes[targetUser] ?? 1.0;

  void setUserVolume(String targetUser, double volume) {
    _userVolumes[targetUser] = volume.clamp(0.0, 2.0);
    _applyVolume(targetUser);
    onParticipantsChanged?.call(_participants);
  }

  static const _audioChannel = MethodChannel('phimhay_app/audio');

  // ── Connection type tracking (P2P vs TURN relay) ──────────
  String _connectionType = 'disconnected'; // 'p2p' | 'relay' | 'disconnected'
  String get connectionType => _connectionType;

  // ── Latency (RTT từ WebRTC stats) ────────────────────────
  int _latencyMs = -1; // -1 = chưa có data
  int get latencyMs => _latencyMs;
  bool _hasWebRtcRtt = false; // true = đang có WebRTC RTT (ưu tiên hơn HTTP RTT)
  Timer? _rttPollTimer; // Periodic WebRTC RTT refresh
  final Map<String, int> _peerRtts = {}; // Per-peer RTT cho EMA
  double _emaPing = -1; // Exponential Moving Average
  static const double _emaAlpha = 0.3; // 30% mới, 70% cũ

  // ── Opus low-latency SDP munging ─────────────────────────
  /// Thêm Opus params vào SDP để giảm latency:
  /// - ptime=20: gói tin 20ms (thấp hơn = ít trễ hơn)
  /// - maxaveragebitrate=32000: 32kbps — đủ cho voice, encode nhanh
  /// - usedtx=1: tắt truyền khi im lặng (tiết kiệm bandwidth)
  /// - stereo=0: mono (giảm dữ liệu)
  String _applyOpusLowLatency(String sdp) {
    // Tìm dòng fmtp cho opus và thêm params
    final lines = sdp.split('\r\n');
    final result = <String>[];
    bool opusFound = false;

    for (final line in lines) {
      if (line.startsWith('a=fmtp:') && line.contains('opus/48000')) {
        opusFound = true;
        // Thêm Opus low-latency params nếu chưa có
        final additions = <String>[];
        if (!line.contains('ptime=')) additions.add('ptime=20');
        if (!line.contains('maxptime=')) additions.add('maxptime=20');
        if (!line.contains('maxaveragebitrate=')) additions.add('maxaveragebitrate=32000');
        if (!line.contains('usedtx=')) additions.add('usedtx=1');
        if (!line.contains('stereo=')) additions.add('stereo=0');

        if (additions.isNotEmpty) {
          result.add('$line;${additions.join(';')}');
        } else {
          result.add(line);
        }
      } else {
        result.add(line);
      }
    }

    // Nếu không tìm thấy fmtp opus (hiếm), thêm mới
    if (!opusFound) {
      for (int i = 0; i < result.length; i++) {
        if (result[i].startsWith('a=rtpmap:') && result[i].contains('opus/48000')) {
          // Lấy payload type từ rtpmap line: a=rtpmap:111 opus/48000/2
          final ptMatch = RegExp(r'a=rtpmap:(\d+)').firstMatch(result[i]);
          if (ptMatch != null) {
            final pt = ptMatch.group(1);
            result.insert(i + 1,
              'a=fmtp:$pt minptime=10;useinbandfec=1;ptime=20;maxptime=20;maxaveragebitrate=32000;usedtx=1;stereo=0');
          }
          break;
        }
      }
    }

    // Thêm ptime attribute vào audio section (nếu chưa có)
    if (!result.any((l) => l.startsWith('a=ptime:'))) {
      for (int i = 0; i < result.length; i++) {
        if (result[i].startsWith('a=rtcp-mux')) {
          result.insert(i + 1, 'a=ptime:20');
          break;
        }
      }
    }

    return result.join('\r\n');
  }

  /// Detect connection type từ ICE candidate pair
  /// getStats() có thể chưa có candidate-pair data ngay → retry sau 1s
  void _detectConnectionType(RTCPeerConnection pc, String peerName) {
    _tryDetectConnectionType(pc, peerName, attempt: 0);
  }

  void _tryDetectConnectionType(RTCPeerConnection pc, String peerName, {required int attempt}) {
    pc.getStats(null).then((stats) {
      String detectedType = 'p2p';
      bool found = false;
      int rttMs = -1;

      // Log TẤT CẢ report types để debug
      final types = stats.map((r) => r.type).toSet().toList();
      _log('Voice: stats types=$types');

      for (final report in stats) {
        // Candidate-pair: state=succeeded hoặc state=active
        if (report.type == 'candidate-pair' &&
            (report.values['state'] == 'succeeded' || report.values['state'] == 'active')) {
          found = true;

          // Log TẤT CẢ keys trong candidate-pair
          _log('Voice: ★ candidate-pair keys=${report.values.keys.toList()}');

          final localId = report.values['localCandidateId']?.toString();
          final remoteId = report.values['remoteCandidateId']?.toString();

          // Đọc RTT — thử nhiều field name
          dynamic rtt = report.values['currentRoundTripTime'];
          rtt ??= report.values['roundTripTime'];
          rtt ??= report.values['totalRoundTripTime'];
          if (rtt is double) {
            rttMs = rtt < 1 ? (rtt * 1000).toInt() : rtt.toInt();
          } else if (rtt is int) {
            rttMs = rtt;
          }
          _log('Voice: ★ RTT raw=$rtt → ${rttMs}ms');

          for (final r in stats) {
            if (r.type == 'local-candidate' && r.values['id']?.toString() == localId) {
              final type = r.values['candidateType']?.toString() ?? '';
              _log('Voice: local candidate type=$type');
              if (type == 'relay') detectedType = 'relay';
            }
            if (r.type == 'remote-candidate' && r.values['id']?.toString() == remoteId) {
              final type = r.values['candidateType']?.toString() ?? '';
              _log('Voice: remote candidate type=$type');
              if (type == 'relay') detectedType = 'relay';
            }
          }
          break;
        }
      }

      if (found) {
        if (detectedType != _connectionType) {
          _connectionType = detectedType;
          onStateChanged?.call();
        }
        if (rttMs >= 0) {
          _peerRtts[peerName] = rttMs;
          _hasWebRtcRtt = true;
          _updateEmaPing();
        }
      } else if (attempt < 3) {
        _log('Voice: no candidate-pair found (attempt ${attempt + 1})');
        Future.delayed(const Duration(seconds: 1), () {
          if (_isJoined) _tryDetectConnectionType(pc, peerName, attempt: attempt + 1);
        });
      }
    }).catchError((e) {
      _log('Voice: getStats error: $e');
      return null;
    });
  }

  /// Periodic WebRTC RTT refresh — mỗi 5s, duyệt tất cả peers
  void _startRttPolling() {
    _stopRttPolling();
    _rttPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_isJoined) { _stopRttPolling(); return; }
      for (final entry in _peers.entries) {
        _tryDetectConnectionType(entry.value, entry.key, attempt: 0);
      }
    });
  }

  void _stopRttPolling() {
    _rttPollTimer?.cancel();
    _rttPollTimer = null;
  }

  /// Tính EMA ping từ tất cả peer RTTs
  void _updateEmaPing() {
    if (_peerRtts.isEmpty) {
      if (_emaPing >= 0) {
        _emaPing = -1;
        _latencyMs = -1;
        onStateChanged?.call();
      }
      return;
    }

    // Trung bình RTT tất cả peer
    final avg = _peerRtts.values.reduce((a, b) => a + b) / _peerRtts.length;

    // Apply EMA
    if (_emaPing < 0) {
      _emaPing = avg;
    } else {
      _emaPing = _emaAlpha * avg + (1 - _emaAlpha) * _emaPing;
    }

    final newLatency = _emaPing.round();
    if (newLatency != _latencyMs) {
      _latencyMs = newLatency;
      _log('Voice: ping=${_latencyMs}ms (avg=${avg.round()}, peers=${_peerRtts.length})');
      onStateChanged?.call();
    }
  }

  /// Setup listener cho callback từ native (iOS interruption recovery)
  void _setupNativeCallbacks() {
    _audioChannel.setMethodCallHandler((call) async {
      if (call.method == 'onAudioSessionResumed') {
        _log('Voice: native audio session resumed (after interruption) — reacquiring mic');
        if (_isJoined) await _reacquireMic();
      }
    });
  }

  void _applyVolume(String targetUser) {
    final vol = _userVolumes[targetUser] ?? 1.0;
    final renderer = _remoteRenderers[targetUser];
    if (renderer == null) return;

    if (vol <= 0 || _speakerMuted || _mutedUsers.contains(targetUser)) {
      // Mute hoàn toàn
      renderer.srcObject?.getAudioTracks().forEach((t) => t.enabled = false);
    } else {
      renderer.srcObject?.getAudioTracks().forEach((t) => t.enabled = true);
    }

    // Tìm max volume trong tất cả users → set device volume tương ứng
    _syncDeviceVolume();
  }

  /// Set device media volume dựa trên max volume trong tất cả users
  void _syncDeviceVolume() {
    double maxVol = 1.0;
    for (final entry in _userVolumes.entries) {
      if (!_mutedUsers.contains(entry.key) && !_speakerMuted) {
        if (entry.value > maxVol) maxVol = entry.value;
      }
    }
    // Set device volume: 1.0 = 100%, 2.0 = max
    try {
      _audioChannel.invokeMethod('setVolume', {'volume': maxVol});
    } catch (_) {}
  }

  /// Force audio output device — loa ngoài (speaker) hoặc loa trong (earpiece)
  void _setSpeaker(bool on) {
    try {
      _audioChannel.invokeMethod('setSpeaker', {'on': on});
      _log('Voice: speaker ${on ? "ON (loudspeaker)" : "OFF (earpiece)"}');
    } catch (e) {
      _log('Voice: setSpeaker error: $e');
    }
  }

  // Grace period: track lần cuối thấy mỗi participant (tránh xóa khi thoáng vắng)
  final Map<String, int> _participantLastSeen = {};
  static const int _gracePolls = 3; // Số poll liên tiếp vắng mặt mới xóa
  int _pollCount = 0;

  // Polling
  Timer? _pollTimer;
  bool _pollActive = false;

  // Auto-rejoin: đếm số lần poll fail liên tiếp → nếu quá ngưỡng → tự rejoin
  int _consecutivePollFails = 0;
  static const int _maxPollFails = 3; // 3 lần fail liên tiếp (× 2s = 6s) → rejoin
  bool _isRejoining = false;

  // Speaking detection timer
  Timer? _speakingTimer;

  // Presence refresh timer — giữ presence sống (giống web, mỗi 5s)
  Timer? _presenceRefreshTimer;

  // Latency poll timer — cập nhật RTT mỗi 5s
  Timer? _latencyPollTimer;

  // ICE servers (TURN + STUN, fetched from server like web)
  List<Map<String, String>> _iceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];

  // ── Fetch TURN credentials (giống web _getIceServers) ──
  Future<void> _fetchIceServers() async {
    try {
      final res = await ApiClient.get('/turn_credentials.php');
      final data = res.data;
      if (data is List && data.isNotEmpty) {
        _iceServers = data.map<Map<String, String>>((item) {
          final map = <String, String>{};
          if (item['urls'] != null) {
            map['urls'] = item['urls'].toString();
          }
          if (item['username'] != null) map['username'] = item['username'].toString();
          if (item['credential'] != null) map['credential'] = item['credential'].toString();
          return map;
        }).toList();
        _log('Voice: fetched ${_iceServers.length} ICE servers');
      }
    } catch (e) {
      _log('Voice: failed to fetch TURN credentials, using STUN only: $e');
    }
  }

  // ── Safe getUserMedia ────────────────────────────────────

  /// Safe getUserMedia with retry — handles permission + empty stream on real devices.
  /// flutter_webrtc tự trigger OS permission dialog khi gọi getUserMedia.
  Future<MediaStream?> _safeGetUserMedia() async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        _log('Voice: getUserMedia attempt ${attempt + 1}/2');
        final stream = await navigator.mediaDevices.getUserMedia({
          'audio': {
            // Standard constraints
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
            // goog* prefix: TRÊN NHIỀU ANDROID, chỉ cái này mới thực sự bật AEC hardware
            // Xóa đi → echo vì AEC không hoạt động
            'googEchoCancellation': true,
            'googAutoGainControl': true,
            'googNoiseSuppression': true,
            // KHÔNG dùng googNoiseSuppression2 — quá mạnh, làm nghẹt tiếng
            // KHÔNG dùng googHighpassFilter — quá lọc, mất tiếng trầm
            'sampleRate': 48000,
            'channelCount': 1,
          },
          'video': false,
        });

        // Validate: phải có ít nhất 1 audio track
        final audioTracks = stream.getAudioTracks();
        if (audioTracks.isNotEmpty) {
          _log('Voice: getUserMedia success — ${audioTracks.length} audio tracks');
          for (final t in audioTracks) {
            _log('Voice: track — kind=${t.kind}, enabled=${t.enabled}, id=${t.id}');
            // Listen for track ended — iOS có thể kill track khi thu hồi permission
            t.onEnded = () {
              _log('Voice: audio track ENDED by OS (id=${t.id}) — reacquiring');
              Future.microtask(() => _reacquireMic());
            };
          }
          return stream;
        }

        // Stream rỗng (0 audio tracks) — dispose và retry
        _log('Voice: getUserMedia returned stream with 0 audio tracks (attempt ${attempt + 1})');
        stream.getTracks().forEach((t) => t.stop());

        if (attempt == 0) {
          _log('Voice: waiting 500ms before retry...');
          await Future.delayed(const Duration(milliseconds: 500));
        }
      } catch (e) {
        _log('Voice: getUserMedia error (attempt ${attempt + 1}): $e');
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    }
    return null;
  }

  // ── Init Mic — gọi khi vào phòng (hiện permission dialog + activate mic) ──
  // Static để gọi từ initState() trước khi tạo VoiceService instance
  static MediaStream? _pendingStream;
  static bool _micInitialized = false;

  /// Reset static mic state — gọi khi leave() để initMic() chạy lại khi join lần tiếp theo
  static void _resetMicState() {
    _pendingStream?.getTracks().forEach((t) => t.stop());
    _pendingStream = null;
    _micInitialized = false;
  }

  static Future<void> initMic() async {
    if (_micInitialized) return;
    _micInitialized = true;
    // KHÔNG gọi configAVSession ở đây — sẽ đổi audio mode và giảm video volume
    // Chỉ config khi thực sự join voice (trong join())

    // getUserMedia → OS hiện permission dialog + activate mic hệ thống
    try {
      _pendingStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
          'googEchoCancellation': true,
          'googAutoGainControl': true,
          'googNoiseSuppression': true,
          'sampleRate': 48000,
          'channelCount': 1,
        },
        'video': false,
      });
      if (_pendingStream != null) {
        // KHÔNG disable track — mic hệ thống LUÔN bật
        // track.enabled = true suốt đời, chỉ kiểm soát truyền qua peer connection
      } else {
      }
    } catch (e) {
    }
  }

  // ── Join ─────────────────────────────────────────────────
  Future<bool> join({List<String> roomVoiceMembers = const []}) async {
    if (_isJoined || _isJoining) return false;
    _isJoining = true;

    try {
      // 1. Fetch TURN credentials
      await _fetchIceServers();

      // 2. Reuse stream từ initMic() nếu có và còn live, nếu không thì getUserMedia lại
      if (_pendingStream != null && _pendingStream!.getAudioTracks().isNotEmpty) {
        _localStream = _pendingStream;
        _pendingStream = null;
        _log('Voice: reusing stream from initMic — ${_localStream!.getAudioTracks().length} tracks');
      } else if (_localStream == null || _localStream!.getAudioTracks().isEmpty) {
        _log('Voice: no stream from initMic, requesting getUserMedia...');
        await _audioChannel.invokeMethod('configAVSession');
        await Future.delayed(const Duration(milliseconds: 200));
        _localStream = await _safeGetUserMedia();
      } else {
        _log('Voice: stream already exists — ${_localStream!.getAudioTracks().length} tracks');
      }

      if (_localStream == null) {
        _log('Voice: getUserMedia failed');
        _isJoining = false;
        return false;
      }

      // Mặc định tắt mic (Discord style: track.enabled=false → mic indicator tắt)
      _isMuted = true;
      _localStream!.getAudioTracks().forEach((t) => t.enabled = false);

      final tracks = _localStream!.getAudioTracks();
      _log('Voice: local stream — ${tracks.length} audio tracks');

      if (tracks.isEmpty) {
        _log('Voice: WARNING — no audio tracks!');
        _localStream?.getTracks().forEach((t) => t.stop());
        _localStream?.dispose();
        _localStream = null;
        _isJoining = false;
        return false;
      }

      // 5. Mặc định dùng earpiece (loa trong) — tránh echo khi dùng loa ngoài
      // User có thể toggle sang speaker bằng nút loa trong UI
      _speakerMuted = true; // true = earpiece mode (mặc định)
      _setSpeaker(false);   // false = earpiece

      // 6. Acquire wake lock (Android) — giữ CPU khi voice trong background
      try {
        await _audioChannel.invokeMethod('acquireWakeLock');
        _log('Voice: wake lock acquired');
      } catch (_) {}

      // 4. Join via signaling — đo ping từ request time
      _log('Voice: joining room=$roomCode user=$userName');
      final sw = Stopwatch()..start();
      final res = await ApiClient.post(
        '/voice_signal.php',
        data: FormData.fromMap({
          'action': 'join',
          'room_code': roomCode,
          'user': userName,
        }),
      );
      sw.stop();
      _latencyMs = sw.elapsedMilliseconds;
      _log('Voice: join response: ${res.data} (ping=${_latencyMs}ms)');
      onStateChanged?.call(); // Trigger UI rebuild để hiện ping
      final data = res.data as Map<String, dynamic>;
      if (data['success'] != true) {
        _isJoining = false;
        return false;
      }

      _isJoined = true;
      _isJoining = false;
      _pollCount = 0;
      _participantLastSeen.clear();
      _log('Voice: joined as $userName (ping=${_latencyMs}ms)');
      onStateChanged?.call(); // Trigger UI rebuild để hiện badge + ping

      // 4. Create offers to existing users — chỉ nếu tên mình > tên họ (tránh glare)
      final existingUsers = (data['existing_users'] as List<dynamic>?) ?? [];
      for (final user in existingUsers) {
        final name = user.toString();
        if (name != userName && userName.compareTo(name) > 0) {
          _log('Voice: creating offer to $name (I am caller)');
          _createOfferTo(name);
        } else if (name != userName) {
          _log('Voice: waiting for offer from $name (I am callee)');
        }
      }

      // 5. Nếu existing_users trống nhưng room có voice_members (từ room sync)
      //    → tạo offers đến họ (server signaling session có thể đã hết hạn)
      if (existingUsers.isEmpty && roomVoiceMembers.isNotEmpty) {
        _log('Voice: existing_users empty but room has ${roomVoiceMembers.length} voice members — creating offers');
        for (final name in roomVoiceMembers) {
          if (name != userName && !_peers.containsKey(name)) {
            if (userName.compareTo(name) > 0) {
              _log('Voice: creating offer to room voice member $name');
              _createOfferTo(name);
            }
          }
        }
      }

      // 5. Start polling + speaking detection + native callbacks
      _setupNativeCallbacks();
      _startPolling();
      _startSpeakingDetection();

      // 6. Auto-reconnect: sau 5s kiểm tra peer chưa connected → retry offer
      Timer(const Duration(seconds: 5), () {
        if (!_isJoined) return;
        for (final entry in _participants.entries) {
          final name = entry.key;
          final pc = _peers[name];
          if (pc == null ||
              pc.iceConnectionState == RTCIceConnectionState.RTCIceConnectionStateFailed ||
              pc.iceConnectionState == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
              pc.iceConnectionState == RTCIceConnectionState.RTCIceConnectionStateNew) {
            _log('Voice: auto-reconnect offer to $name (ICE state: ${pc?.iceConnectionState})');
            if (pc != null) {
              try { pc.close(); } catch (_) {}
            }
            _peers.remove(name);
            _remoteRenderers[name]?.dispose();
            _remoteRenderers.remove(name);
            _createOfferTo(name);
          }
        }
      });

      onStateChanged?.call();
      return true;
    } catch (e) {
      _isJoining = false;
      _localStream?.getTracks().forEach((t) => t.stop());
      _localStream = null;
      return false;
    }
  }

  // ── Leave ────────────────────────────────────────────────
  Future<void> leave() async {
    if (!_isJoined || _isLeaving) return;
    _isLeaving = true;

    _pollTimer?.cancel();
    _pollActive = false;
    _speakingTimer?.cancel();
    _presenceRefreshTimer?.cancel();
    _latencyPollTimer?.cancel();

    // Close all peer connections
    _peers.forEach((name, pc) {
      try { pc.close(); } catch (_) {}
    });
    _peers.clear();
    _iceQueues.clear();
    _remoteDescSet.clear();
    _creatingOfferFor.clear();

    // Dispose renderers
    _remoteRenderers.forEach((_, r) {
      try { r.dispose(); } catch (_) {}
    });
    _remoteRenderers.clear();

    // Reset speaker về loa trong khi leave voice
    _setSpeaker(false);

    // Release wake lock (Android)
    try {
      await _audioChannel.invokeMethod('releaseWakeLock');
      _log('Voice: wake lock released');
    } catch (_) {}

    // Stop local stream + reset static mic state
    // (cho phép initMic() chạy lại khi join lần tiếp theo)
    _resetMicState();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream = null;

    // Leave via signaling
    try {
      await ApiClient.post(
        '/voice_signal.php',
        data: FormData.fromMap({
          'action': 'leave',
          'room_code': roomCode,
          'user': userName,
        }),
      );
    } catch (_) {}

    _isJoined = false;
    _isMuted = true;
    _isSpeaking = false;
    _isLeaving = false;
    _connectionType = 'disconnected';
    _latencyMs = -1;
    _hasWebRtcRtt = false;
    _stopRttPolling();
    _peerRtts.clear();
    _emaPing = -1;
    _participants.clear();
    _mutedUsers.clear();
    _participantLastSeen.clear();
    _pollCount = 0;

    onStateChanged?.call();
    onParticipantsChanged?.call(_participants);
  }

  // ── Mic Toggle ───────────────────────────────────────────
  /// Toggle mic — Discord style: track.enabled kiểm soát mic hệ thống
  /// track.enabled=false → mic indicator tắt, không capture audio
  /// track.enabled=true  → mic indicator sáng, audio capture + gửi đi
  void toggleMic() {
    if (!_isJoined) return;
    if (_localStream == null || _localStream!.getAudioTracks().isEmpty) {
      _log('Voice: toggleMic — no stream/tracks, reacquiring');
      _reacquireMic();
      return;
    }

    // Đảo trạng thái mute
    _isMuted = !_isMuted;
    _isSpeaking = false;

    // Discord approach: track.enabled trực tiếp kiểm soát mic hệ thống
    // false = mic indicator tắt (giống Discord khi mute)
    // true  = mic indicator sáng (giống Discord khi unmute)
    _localStream!.getAudioTracks().forEach((t) {
      t.enabled = !_isMuted;
    });

    _log('Voice: toggleMic — muted=$_isMuted, track.enabled=${_localStream!.getAudioTracks().first.enabled}');

    onStateChanged?.call();

    // Thông báo UI để restore/reduce video volume
    onMicToggled?.call(_isMuted);

    // Gửi presence cho server
    _syncPresenceWithSpeaking();
    Future.delayed(const Duration(milliseconds: 400), _syncPresenceWithSpeaking);
  }

  /// Re-acquire mic — dispose stream cũ, tạo stream mới, re-add tracks vào peers
  Future<void> _reacquireMic() async {
    _log('Voice: === REACQUIRING MIC ===');

    // Dispose old stream
    _localStream?.getTracks().forEach((t) {
      _log('Voice: disposing old track — id=${t.id}, kind=${t.kind}');
      t.stop();
    });
    _localStream = null;

    // Get new stream — config AVSession trước (quan trọng trên iOS)
    try {
      await _audioChannel.invokeMethod('configAVSession');
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (e) {
      _log('Voice: reacquire configAVSession error: $e');
    }
    final newStream = await _safeGetUserMedia();
    if (newStream == null) {
      _log('Voice: reacquire FAILED — getUserMedia returned null');
      _isMuted = true;
      onStateChanged?.call();
      return;
    }

    _localStream = newStream;

    // Log new track state
    for (final t in newStream.getAudioTracks()) {
      _log('Voice: new track — enabled=${t.enabled}, muted=${t.muted}, id=${t.id}');
    }

    // Đồng bộ track.enabled với trạng thái mute hiện tại (Discord style)
    // Không force disable — nếu đang unmute thì track phải enabled
    newStream.getAudioTracks().forEach((t) => t.enabled = !_isMuted);
    _log('Voice: reacquire — track.enabled=${!_isMuted} (isMuted=$_isMuted)');

    // Re-add tracks to existing peer connections.
    // DÙNG replaceTrack (KHÔNG remove+add+offer mới):
    // - remove+add track trigger renegotiation → peer nhận offer mới → _handleOffer
    //   close PC cũ và tạo PC mới → trong khoảng đó 2 PC cùng tồn tại → double audio
    // - replaceTrack chỉ swap track trong sender hiện có, KHÔNG cần renegotiate SDP
    //   → không tạo PC mới → không double audio trên mobile ↔ mobile
    final newAudioTrack = newStream.getAudioTracks().isNotEmpty
        ? newStream.getAudioTracks().first
        : null;

    for (final entry in _peers.entries) {
      final name = entry.key;
      final pc = entry.value;
      try {
        final senders = await pc.getSenders();
        final audioSender = senders.firstWhere(
          (s) => s.track?.kind == 'audio',
          orElse: () => throw StateError('no audio sender'),
        );
        if (newAudioTrack != null) {
          await audioSender.replaceTrack(newAudioTrack);
          _log('Voice: replaceTrack on peer $name — id=${newAudioTrack.id}');
        }
      } catch (e) {
        _log('Voice: replaceTrack failed for $name ($e) — fallback re-add+renegotiate');
        // Fallback khi sender không tồn tại (peer mới join sau khi stream cũ die)
        try {
          if (newAudioTrack != null) {
            await pc.addTrack(newAudioTrack, newStream);
            final offer = await pc.createOffer();
            // Opus low-latency: munge SDP
            final lowLatencySdp = _applyOpusLowLatency(offer.sdp ?? '');
            final lowLatencyOffer = RTCSessionDescription(lowLatencySdp, offer.type);
            await pc.setLocalDescription(lowLatencyOffer);
            _sendSignal('offer', name, lowLatencyOffer.toMap());
            _log('Voice: fallback renegotiated offer to $name after reacquire (opusLowLatency=true)');
          }
        } catch (e2) {
          _log('Voice: fallback also failed for $name: $e2');
          _handlePeerLeft(name);
        }
      }
    }

    _log('Voice: === REACQUIRE DONE — ${newStream.getAudioTracks().length} tracks ===');
    onStateChanged?.call();
  }

  // ── Speaker Toggle (mute/unmute all remote audio) ────────
  void toggleSpeaker() {
    _speakerMuted = !_speakerMuted;
    for (final name in _remoteRenderers.keys) {
      _applyVolume(name);
    }
    onStateChanged?.call();
  }

  // ── Audio Output Toggle (earpiece ↔ speaker) ────────────
  bool _isSpeakerOutput = false; // false = earpiece, true = speaker
  bool get isSpeakerOutput => _isSpeakerOutput;

  void toggleSpeakerOutput() {
    _isSpeakerOutput = !_isSpeakerOutput;
    _setSpeaker(_isSpeakerOutput);
    onSpeakerToggled?.call(_isSpeakerOutput);
    onStateChanged?.call();
  }

  // ── Per-user Mute ────────────────────────────────────────
  void toggleUserMute(String targetUser) {
    if (_mutedUsers.contains(targetUser)) {
      _mutedUsers.remove(targetUser);
    } else {
      _mutedUsers.add(targetUser);
    }
    _applyVolume(targetUser);
    onParticipantsChanged?.call(_participants);
  }

  bool isUserMuted(String targetUser) => _mutedUsers.contains(targetUser);

  // ── Signaling ────────────────────────────────────────────
  void _startPolling() {
    _pollTimer?.cancel();
    _pollActive = true;
    // FIX: Tăng từ 1s → 2s — giảm tải server + tiết kiệm pin
    // Voice signaling chỉ cần nhanh khi mới join/reconnect, còn lại rất ít SDP exchange
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollSignals());

    // Presence refresh: giữ presence sống mỗi 5 giây
    _presenceRefreshTimer?.cancel();
    _presenceRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_isJoined) _syncPresenceWithSpeaking();
    });

  }

  Future<void> _pollSignals() async {
    if (!_isJoined || !_pollActive || _isRejoining) return;

    try {
      // Đo HTTP RTT làm ping
      final sw = Stopwatch()..start();
      final res = await ApiClient.post(
        '/voice_signal.php',
        data: FormData.fromMap({
          'action': 'get_signals',
          'room_code': roomCode,
          'user': userName,
          'is_muted': _isMuted ? '1' : '0',
          'is_speaking': _isSpeaking ? '1' : '0',
        }),
      );
      sw.stop();
      final newPing = sw.elapsedMilliseconds;
      // HTTP RTT chỉ dùng khi CHƯA có WebRTC RTT (fallback)
      if (!_hasWebRtcRtt && newPing != _latencyMs) {
        _latencyMs = newPing;
        onStateChanged?.call();
      }

      final data = res.data as Map<String, dynamic>;
      if (data['success'] != true) {
        // FIX: Đếm fail liên tiếp → auto-rejoin sau _maxPollFails lần
        _consecutivePollFails++;
        _log('Voice: poll failed (${_consecutivePollFails}/$_maxPollFails)');
        if (_consecutivePollFails >= _maxPollFails) {
          _log('Voice: too many poll fails — auto rejoining...');
          _autoRejoin();
        }
        return;
      }
      // Poll thành công → reset counter
      _consecutivePollFails = 0;

      // Process signals
      final signals = (data['signals'] as List<dynamic>?) ?? [];
      for (final sig in signals) {
        final type = sig['type']?.toString() ?? '';
        final fromUser = sig['from_user']?.toString() ?? '';
        final payload = sig['payload']?.toString() ?? '{}';
        switch (type) {
          case 'new_peer':
            // FIX: Chỉ user có TÊN LỚN HƠN mới tạo offer (tránh glare)
            // User có tên nhỏ hơn sẽ chờ offer từ bên kia
            if (userName.compareTo(fromUser) > 0) {
              _log('Voice: new_peer from $fromUser — I am caller (name > theirs), creating offer');
              if (_peers.containsKey(fromUser)) {
                try { _peers[fromUser]?.close(); } catch (_) {}
                _peers.remove(fromUser);
                _remoteRenderers[fromUser]?.dispose();
                _remoteRenderers.remove(fromUser);
              }
              await _createOfferTo(fromUser);
            } else {
              _log('Voice: new_peer from $fromUser — I am callee (name < theirs), waiting for offer');
            }
            break;
          case 'offer':
            await _handleOffer(fromUser, payload);
            break;
          case 'answer':
            await _handleAnswer(fromUser, payload);
            break;
          case 'ice_candidate':
            await _handleIceCandidate(fromUser, payload);
            break;
          case 'peer_left':
            _handlePeerLeft(fromUser);
            break;
        }
      }

      // Update online users — MERGE thay vì replace
      final onlineUsers = (data['online_users'] as List<dynamic>?) ?? [];
      _mergeParticipants(onlineUsers);
    } catch (e) {
    }

    // Notify UI to rebuild (giữ UI sync — quan trọng cho mobile)
    onPollCompleted?.call();
  }

  /// Auto-rejoin: leave sạch sẽ rồi join lại (giữ nguyên callback)
  Future<void> _autoRejoin() async {
    if (_isRejoining) return;
    _isRejoining = true;
    _log('Voice: === AUTO REJOIN START ===');

    try {
      // Leave nhưng không gọi onStateChanged để UI không flicker
      _pollTimer?.cancel();
      _pollActive = false;
      _speakingTimer?.cancel();
      _presenceRefreshTimer?.cancel();
      _stopRttPolling();
      _hasWebRtcRtt = false;
      _peerRtts.clear();
      _emaPing = -1;

      // Close all peer connections
      _peers.forEach((name, pc) {
        try { pc.close(); } catch (_) {}
      });
      _peers.clear();
      _iceQueues.clear();
      _remoteDescSet.clear();
      _creatingOfferFor.clear();

      // Dispose renderers
      _remoteRenderers.forEach((_, r) {
        try { r.dispose(); } catch (_) {}
      });
      _remoteRenderers.clear();

      // Leave signaling (không chờ kết quả)
      try {
        await ApiClient.post(
          '/voice_signal.php',
          data: FormData.fromMap({
            'action': 'leave',
            'room_code': roomCode,
            'user': userName,
          }),
        );
      } catch (_) {}

      // Reset state
      _isJoined = false;
      _participants.clear();
      _participantLastSeen.clear();
      _pollCount = 0;
      _consecutivePollFails = 0;

      // Đợi 1s rồi join lại
      await Future.delayed(const Duration(seconds: 1));

      if (!_isRejoining) return; // Đã bị cancel

      // Join lại — giữ nguyên stream hiện có (không getUserMedia lại)
      _log('Voice: auto rejoin — fetching ICE + re-registering...');
      await _fetchIceServers();

      final sw = Stopwatch()..start();
      final res = await ApiClient.post(
        '/voice_signal.php',
        data: FormData.fromMap({
          'action': 'join',
          'room_code': roomCode,
          'user': userName,
        }),
      );
      sw.stop();
      _latencyMs = sw.elapsedMilliseconds; // Đo RTT khi rejoin
      final data = res.data as Map<String, dynamic>;
      if (data['success'] != true) {
        _log('Voice: auto rejoin FAILED — join returned false');
        _isJoined = false;
        onStateChanged?.call();
        return;
      }

      _isJoined = true;
      _pollCount = 0;
      _participantLastSeen.clear();
      _log('Voice: auto rejoin SUCCESS — ping=${_latencyMs}ms, creating offers');

      // Create offers to existing users
      final existingUsers = (data['existing_users'] as List<dynamic>?) ?? [];
      for (final user in existingUsers) {
        final name = user.toString();
        if (name != userName && userName.compareTo(name) > 0) {
          _createOfferTo(name);
        }
      }

      // Restart polling + speaking detection
      _startPolling();
      _startSpeakingDetection();
      onStateChanged?.call();

      _log('Voice: === AUTO REJOIN DONE ===');
    } catch (e) {
      _log('Voice: auto rejoin error: $e');
    } finally {
      _isRejoining = false;
    }
  }

  /// Merge participants — không clear, chỉ update/add/remove
  /// Grace period: chỉ xóa participant sau khi vắng mặt _gracePolls lần liên tiếp
  void _mergeParticipants(List<dynamic> onlineUsers) {
    final currentNames = <String>{};
    bool changed = false;
    _pollCount++;

    for (final u in onlineUsers) {
      final name = u['name']?.toString() ?? '';
      if (name == userName || name.isEmpty) continue;
      currentNames.add(name);

      // Đánh dấu đã thấy participant này
      _participantLastSeen[name] = _pollCount;

      final existing = _participants[name];
      final newMuted = u['is_muted'] == true;
      final newSpeaking = u['is_speaking'] == true;
      final newAvatar = u['avatar']?.toString() ?? '';

      if (existing == null) {
        _participants[name] = VoiceParticipantState(
          name: name,
          avatar: newAvatar,
          isMuted: newMuted,
          isSpeaking: newSpeaking,
        );
        changed = true;
      } else if (existing.isMuted != newMuted || existing.isSpeaking != newSpeaking || (newAvatar.isNotEmpty && existing.avatar != newAvatar)) {
        _participants[name] = VoiceParticipantState(
          name: name,
          avatar: newAvatar.isNotEmpty ? newAvatar : existing.avatar,
          isMuted: newMuted,
          isSpeaking: newSpeaking,
        );
        changed = true;
      }
    }

    // Remove users vắng mặt quá lâu (grace period) + cleanup PeerConnection
    // NHƯNG KHÔNG xóa nếu WebRTC vẫn connected (server có thể chưa sync)
    final toRemove = <String>[];
    for (final name in _participants.keys) {
      if (!currentNames.contains(name)) {
        // Nếu WebRTC vẫn connected → giữ lại, server sẽ sync sau
        if (isPeerConnected(name)) {
          _log('Voice: $name absent from server but WebRTC connected — keeping');
          continue;
        }
        final lastSeen = _participantLastSeen[name] ?? 0;
        final absentPolls = _pollCount - lastSeen;
        if (absentPolls >= _gracePolls) {
          toRemove.add(name);
        }
      }
    }
    for (final name in toRemove) {
      _participants.remove(name);
      _participantLastSeen.remove(name);
      // Cleanup peer connection
      if (_peers.containsKey(name)) {
        try { _peers[name]?.close(); } catch (_) {}
        _peers.remove(name);
      }
      _remoteRenderers[name]?.dispose();
      _remoteRenderers.remove(name);
      changed = true;
    }

    if (changed) {
      onParticipantsChanged?.call(_participants);
      onVoiceMembersUpdated?.call(
        _participants.values.map((p) => {
          'name': p.name,
          'avatar': p.avatar,
          'is_muted': p.isMuted,
          'is_speaking': p.isSpeaking,
        }).toList(),
      );
    }
  }

  // ── WebRTC ───────────────────────────────────────────────
  Future<RTCPeerConnection> _createPeerConnection(String targetUser) async {
    final config = {
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
      'iceCandidatePoolSize': 10,
      'iceTransportPolicy': 'all',
    };

    final pc = await createPeerConnection(config);

    // Initialize ICE candidate queue for this peer
    _iceQueues[targetUser] = [];
    _remoteDescSet.remove(targetUser); // Reset flag cho peer mới

    // Discord approach: addTrack() + transceiver direction kiểm soát truyền âm thanh
    // Track LUÔN enabled (mic hệ thống luôn bật), direction quyết định truyền hay không
    if (_localStream != null) {
      final audioTracks = _localStream!.getAudioTracks();
      for (final track in audioTracks) {
        _log('Voice: adding track to $targetUser — kind=${track.kind}, enabled=${track.enabled}, id=${track.id}');
        await pc.addTrack(track, _localStream!);
      }

      // Discord approach: track.enabled đã kiểm soát mic rồi → direction luôn SendRecv
      // track.enabled=false → không gửi audio dù direction SendRecv (OS tắt capture)
      // track.enabled=true  → gửi audio bình thường
      final transceivers = await pc.getTransceivers();
      for (final t in transceivers) {
        if (t.sender.track?.kind == 'audio') {
          await t.setDirection(TransceiverDirection.SendRecv);
          _log('Voice: set SendRecv for $targetUser (track.enabled=${t.sender.track?.enabled} controls actual send)');
          break;
        }
      }

      _log('Voice: added ${audioTracks.length} local tracks to peer $targetUser');
    } else {
      _log('Voice: WARNING — _localStream is NULL when creating PC for $targetUser');
    }

    // ICE candidates → gửi qua signaling (trickle ICE)
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      // FIX: Wrap candidate trong object giống web {candidate: {candidate, sdpMid, sdpMLineIndex}}
      _sendSignal('ice_candidate', targetUser, {
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };

    // Remote track → tạo renderer để phát audio
    pc.onTrack = (event) {
      _log('Voice: onTrack from $targetUser — streams=${event.streams.length}, track.kind=${event.track?.kind}, track.enabled=${event.track?.enabled}');
      if (event.streams.isNotEmpty) {
        final stream = event.streams[0];
        _log('Voice: remote stream tracks=${stream.getAudioTracks().length} audio, ${stream.getVideoTracks().length} video');
        _setupRemoteAudio(targetUser, stream);
      }
    };

    // NOTE: onAddStream đã bị XÓA — nó fire đồng thời với onTrack trên nhiều
    // phiên bản flutter_webrtc, gây double renderer → âm thanh phát 2 lần (echo giả).
    // Chỉ dùng onTrack (Unified Plan) là đủ.

    // Connection state — auto-reconnect (giống web)
    pc.onIceConnectionState = (state) {
      _log('Voice: ★ ICE state for $targetUser: $state');

      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _log('Voice: ✅ ICE CONNECTED with $targetUser!');
        // Log remote stream info
        final streams = pc.getRemoteStreams();
        for (final s in streams) {
          if (s != null) {
            _log('Voice: remote stream id=${s.id}, audioTracks=${s.getAudioTracks().length}');
          }
        }
        // Detect P2P vs TURN relay → hiển thị trên UI
        _detectConnectionType(pc, targetUser);
        // Bắt đầu periodic RTT refresh
        if (_rttPollTimer == null) _startRttPolling();

        // FIX: Nếu peer đã connected nhưng không có trong participant list
        // (server presence cũ, không trả về trong online_users) → tự động thêm
        if (!_participants.containsKey(targetUser)) {
          _log('Voice: peer $targetUser connected but NOT in participants — auto-adding');
          _participants[targetUser] = VoiceParticipantState(
            name: targetUser,
            avatar: '',
            isMuted: false, // Đang connected → giả sử không muted
            isSpeaking: false,
          );
          onParticipantsChanged?.call(_participants);
          onVoiceMembersUpdated?.call(
            _participants.values.map((p) => {
              'name': p.name,
              'avatar': p.avatar,
              'is_muted': p.isMuted,
              'is_speaking': p.isSpeaking,
            }).toList(),
          );
        }
      }
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _log('Voice: ICE FAILED with $targetUser - reconnecting');
        _handlePeerLeft(targetUser);
        // Bên có tên NHỎ HƠN là caller → tạo offer mới (nhất quán với glare resolution)
        if (_isJoined && userName.compareTo(targetUser) < 0) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (_isJoined) _createOfferTo(targetUser);
          });
        }
        // Bên có tên lớn hơn chờ offer đến từ bên kia (không cần tạo offer)
      }
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        // Đợi 1.5s rồi reconnect (có thể tự phục hồi, giống web)
        Future.delayed(const Duration(milliseconds: 1500), () async {
          if (!_isJoined) return;
          final pc2 = _peers[targetUser];
          if (pc2 == null) return;
          // Nếu đã reconnect thì bỏ qua
          if (pc2.iceConnectionState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
              pc2.iceConnectionState == RTCIceConnectionState.RTCIceConnectionStateCompleted) return;
          _log('Voice: reconnecting after disconnect with $targetUser');
          _handlePeerLeft(targetUser);
          // Nhất quán: bên tên nhỏ hơn làm caller
          if (userName.compareTo(targetUser) < 0) {
            await _createOfferTo(targetUser);
          }
        });
      }
    };

    _peers[targetUser] = pc;
    return pc;
  }

  /// Setup remote audio — tạo renderer và phát.
  /// QUAN TRỌNG: dùng _setupRemoteAudioLock để tránh 2 lần chạy song song
  /// cho cùng 1 user → double renderer → double audio (echo giả).
  final Map<String, bool> _setupLock = {};

  void _setupRemoteAudio(String targetUser, MediaStream stream) {
    // Nếu đang setup cho user này rồi → bỏ qua, tránh race condition
    if (_setupLock[targetUser] == true) {
      _log('Voice: _setupRemoteAudio for $targetUser already in progress — skipping duplicate');
      return;
    }
    _setupLock[targetUser] = true;

    // Lấy renderer cũ ra ngay (đồng bộ) trước khi vào async
    final oldRenderer = _remoteRenderers.remove(targetUser);

    Future(() async {
      try {
        // Await dispose hoàn toàn renderer cũ trước khi tạo mới
        if (oldRenderer != null) {
          try {
            oldRenderer.srcObject = null; // detach stream trước
            await oldRenderer.dispose();
          } catch (_) {}
        }

        if (!_isJoined) return; // Guard: có thể đã leave trong lúc await

        final renderer = RTCVideoRenderer();
        try {
          await renderer.initialize();
        } catch (e) {
          _log('Voice: ERROR initializing renderer for $targetUser: $e');
          return;
        }

        if (!_isJoined) {
          // Đã leave trong lúc initialize → dispose luôn
          try { renderer.dispose(); } catch (_) {}
          return;
        }

        // Nếu trong lúc await đã có renderer mới (race) → dispose cái vừa tạo
        if (_remoteRenderers.containsKey(targetUser)) {
          _log('Voice: renderer for $targetUser already replaced during init — disposing new one');
          try { renderer.dispose(); } catch (_) {}
          return;
        }

        renderer.srcObject = stream;
        _remoteRenderers[targetUser] = renderer;

        // Apply per-user volume và mute state
        final vol = _userVolumes[targetUser] ?? 1.0;
        final shouldMute = _speakerMuted || _mutedUsers.contains(targetUser) || vol <= 0;
        stream.getAudioTracks().forEach((t) {
          t.enabled = !shouldMute;
          _log('Voice: remote audio track from $targetUser — kind=${t.kind}, enabled=${t.enabled}, muted=${t.muted}, id=${t.id}');
        });

        if (!shouldMute) {
          _syncDeviceVolume();
          // FIX: re-assert speaker khi nhận remote audio track
          // iOS có thể reset audio routing về earpiece sau khi remote track đến
          _setSpeaker(!_speakerMuted);
        }

        _log('Voice: remote audio renderer set for $targetUser, vol=$vol, muted=$shouldMute, streamId=${stream.id}');
      } finally {
        _setupLock.remove(targetUser);
      }
    });
  }

  Future<void> _createOfferTo(String targetUser) async {
    if (_creatingOfferFor.contains(targetUser)) return;
    _creatingOfferFor.add(targetUser);

    try {
      // Close existing connection
      if (_peers.containsKey(targetUser)) {
        try { _peers[targetUser]?.close(); } catch (_) {}
        _peers.remove(targetUser);
      }

      final pc = await _createPeerConnection(targetUser);
      final offer = await pc.createOffer();

      // Opus low-latency: munge SDP trước khi set local description
      final lowLatencySdp = _applyOpusLowLatency(offer.sdp ?? '');
      final lowLatencyOffer = RTCSessionDescription(lowLatencySdp, offer.type);
      await pc.setLocalDescription(lowLatencyOffer);
      _log('Voice: sending offer to $targetUser — hasAudio=${offer.sdp?.contains('m=audio')}, opusLowLatency=true');

      _sendSignal('offer', targetUser, lowLatencyOffer.toMap());
    } finally {
      _creatingOfferFor.remove(targetUser);
    }
  }

  Future<void> _handleOffer(String fromUser, String sdp) async {
    _log('Voice: handling offer from $fromUser — sdpLen=${sdp.length}');

    final existingPc = _peers[fromUser];
    if (existingPc != null) {
      final sigState = existingPc.signalingState;
      final iceState = existingPc.iceConnectionState;

      // Nếu PC đang stable + ICE đã connected → đây là renegotiate (thay track, không phải
      // reconnect mới). KHÔNG close PC, chỉ setRemoteDescription + answer lại trên PC cũ.
      // Nếu close PC ở đây → onTrack fire lại → _setupRemoteAudio tạo renderer mới
      // trong khi renderer cũ chưa dispose → double audio trên mobile ↔ mobile.
      final isRenegotiate = sigState == RTCSignalingState.RTCSignalingStateStable &&
          (iceState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
           iceState == RTCIceConnectionState.RTCIceConnectionStateCompleted);

      if (isRenegotiate) {
        _log('Voice: renegotiate offer from $fromUser (PC stable+connected) — reusing PC');
        try {
          final offerJson = jsonDecode(sdp);
          await existingPc.setRemoteDescription(RTCSessionDescription(offerJson['sdp'], offerJson['type']));
        } catch (_) {
          await existingPc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
        }
        final answer = await existingPc.createAnswer();
        // Opus low-latency: munge SDP
        final lowLatencySdp = _applyOpusLowLatency(answer.sdp ?? '');
        final lowLatencyAnswer = RTCSessionDescription(lowLatencySdp, answer.type);
        await existingPc.setLocalDescription(lowLatencyAnswer);
        _sendSignal('answer', fromUser, lowLatencyAnswer.toMap());
        _log('Voice: sent renegotiate answer to $fromUser (opusLowLatency=true)');
        return;
      }

      if (sigState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        // Glare: cả 2 cùng offer đồng thời.
        // KHÔNG bỏ qua — bên có tên nhỏ hơn giữ vai caller (offer của mình thắng),
        // bên có tên LỚN HƠN rollback và chấp nhận offer đến (trở thành answerer).
        if (userName.compareTo(fromUser) < 0) {
          // Mình là caller (tên nhỏ hơn) → giữ offer của mình, bỏ qua offer đến
          _log('Voice: glare resolution — I am caller ($userName < $fromUser), keeping my offer');
          return;
        }
        // Mình là answerer (tên lớn hơn) → close PC cũ + dispose renderer cũ, chấp nhận offer đến
        _log('Voice: glare resolution — I yield ($userName > $fromUser), accepting their offer');
        try { existingPc.close(); } catch (_) {}
        _peers.remove(fromUser);
        _remoteDescSet.remove(fromUser);
        _iceQueues.remove(fromUser);
        // FIX: dispose renderer cũ để tránh memory leak + double audio
        _remoteRenderers[fromUser]?.srcObject = null;
        _remoteRenderers[fromUser]?.dispose();
        _remoteRenderers.remove(fromUser);
      } else {
        // Peer cũ ở trạng thái khác — close và tạo mới
        try { existingPc.close(); } catch (_) {}
        _peers.remove(fromUser);
      }
    }

    final pc = await _createPeerConnection(fromUser);

    try {
      final offerJson = jsonDecode(sdp);
      await pc.setRemoteDescription(RTCSessionDescription(offerJson['sdp'], offerJson['type']));
    } catch (_) {
      // Fallback: treat as raw SDP
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    }
    _remoteDescSet.add(fromUser);

    // Flush queued ICE candidates
    _flushIceCandidates(fromUser);

    final answer = await pc.createAnswer();
    // Opus low-latency: munge SDP
    final lowLatencySdp = _applyOpusLowLatency(answer.sdp ?? '');
    final lowLatencyAnswer = RTCSessionDescription(lowLatencySdp, answer.type);
    await pc.setLocalDescription(lowLatencyAnswer);
    _log('Voice: sending answer to $fromUser — SDP type=${lowLatencyAnswer.type}, sdpLen=${lowLatencyAnswer.sdp?.length}, hasAudio=${lowLatencyAnswer.sdp?.contains('m=audio')}, opusLowLatency=true');

    _sendSignal('answer', fromUser, answer.toMap());
  }

  Future<void> _handleAnswer(String fromUser, String sdp) async {
    final pc = _peers[fromUser];
    if (pc == null) return;

    _log('Voice: handling answer from $fromUser');
    if (pc.signalingState != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      _log('Voice: ignoring answer from $fromUser, state=${pc.signalingState}');
      return;
    }

    try {
      final answerJson = jsonDecode(sdp);
      await pc.setRemoteDescription(RTCSessionDescription(answerJson['sdp'], answerJson['type']));
    } catch (_) {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    }
    _remoteDescSet.add(fromUser);

    // Flush queued ICE candidates
    _flushIceCandidates(fromUser);
  }

  Future<void> _handleIceCandidate(String fromUser, String payload) async {
    final pc = _peers[fromUser];
    if (pc == null) return;

    try {
      final data = jsonDecode(payload);

      // FIX: Hỗ trợ cả 2 format — web gửi {candidate: {candidate, sdpMid, sdpMLineIndex}}
      // còn app gửi flat {candidate, sdpMid, sdpMLineIndex}
      Map<String, dynamic> candidateData;
      if (data['candidate'] is Map) {
        // Web format: {candidate: {candidate: "...", sdpMid: "...", sdpMLineIndex: ...}}
        candidateData = data['candidate'];
      } else {
        // App format (flat): {candidate: "...", sdpMid: "...", sdpMLineIndex: ...}
        candidateData = data;
      }

      final candidate = RTCIceCandidate(
        candidateData['candidate'],
        candidateData['sdpMid'],
        candidateData['sdpMLineIndex'],
      );

      // Queue nếu chưa có remote description (giống web)
      if (!_remoteDescSet.contains(fromUser)) {
        _iceQueues[fromUser] ??= [];
        _iceQueues[fromUser]!.add(candidate);
        _log('Voice: queued ICE candidate from $fromUser (no remote desc yet)');
      } else {
        await pc.addCandidate(candidate);
      }
    } catch (e) {
      _log('Voice: ICE candidate error from $fromUser: $e');
    }
  }

  /// Flush queued ICE candidates (giống web _flushIceCandidates)
  void _flushIceCandidates(String targetUser) {
    final queue = _iceQueues[targetUser];
    if (queue == null || queue.isEmpty) return;
    final pc = _peers[targetUser];
    if (pc == null) return;
    for (final candidate in queue) {
      try {
        pc.addCandidate(candidate);
      } catch (_) {}
    }
    queue.clear();
  }

  void _handlePeerLeft(String fromUser) {
    _log('Voice: peer left: $fromUser');
    _peers[fromUser]?.close();
    _peers.remove(fromUser);
    _iceQueues.remove(fromUser);
    _remoteDescSet.remove(fromUser);
    _creatingOfferFor.remove(fromUser);
    _remoteRenderers[fromUser]?.dispose();
    _remoteRenderers.remove(fromUser);
    _participants.remove(fromUser);
    _participantLastSeen.remove(fromUser);
    _peerRtts.remove(fromUser); // Xóa RTT của peer rời
    _updateEmaPing(); // Tính lại EMA
    _mutedUsers.remove(fromUser);
    onParticipantsChanged?.call(_participants);
  }

  /// Gửi signal qua voice_signal.php
  /// offer/answer/ice_candidate: payload gửi qua raw body (php://input)
  /// FIX: Đảm bảo payload luôn là JSON string hợp lệ
  Future<void> _sendSignal(String action, String toUser, dynamic payload) async {
    try {
      final queryParams = {
        'action': action,
        'room_code': roomCode,
        'user': userName,
        'to_user': toUser,
      };

      // Đảm bảo payload luôn là JSON string
      final payloadStr = payload is String ? payload : jsonEncode(payload);
      final payloadBytes = utf8.encode(payloadStr);

      _log('Voice: sending $action to $toUser (${payloadBytes.length} bytes)');

      await ApiClient.dio.post(
        '/voice_signal.php',
        queryParameters: queryParams,
        data: payloadStr,  // Gửi JSON string trực tiếp (giống web Content-Type: application/json)
        options: Options(
          contentType: 'application/json',
          headers: {'Content-Length': payloadBytes.length},
        ),
      );
    } catch (e) {
    }
  }

  // ── Speaking Detection ───────────────────────────────────
  /// Mobile không có AnalyserNode như web → KHÔNG tự detect speaking.
  /// Chỉ hiển thị speaking state mà server gửi về (web detect qua AnalyserNode).
  /// _isSpeaking chỉ dùng để gửi lên server, không tự set = true khi mic mở.
  int _lastBytesSent = 0;

  /// Detect speaking bằng WebRTC stats — track delta bytes + audioLevel
  void _startSpeakingDetection() {
    _speakingTimer?.cancel();
    _lastBytesSent = 0;
    // FIX: Tăng từ 300ms → 500ms — giảm tần suất getStats(), tiết kiệm CPU + pin
    _speakingTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!_isJoined || _isMuted || _localStream == null) {
        if (_isSpeaking) {
          _isSpeaking = false;
          _lastBytesSent = 0;
          onStateChanged?.call();
          _syncPresenceWithSpeaking();
        }
        return;
      }

      if (_peers.isEmpty) return;

      // FIX: Tìm peer nào đang connected/completed (không lấy đại peer đầu tiên)
      // Peer đầu tiên có thể đã disconnected nhưng chưa bị xóa khỏi map
      RTCPeerConnection? pc;
      for (final entry in _peers.entries) {
        final state = entry.value.iceConnectionState;
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          pc = entry.value;
          break;
        }
      }
      if (pc == null) return; // Không có peer nào connected → bỏ qua
      pc.getStats(null).then((stats) {
        bool speaking = false;

        for (final report in stats) {
          // Track delta bytesSent — chỉ speaking khi bytes tăng đáng kể
          if (report.type == 'outbound-rtp' && report.values['kind'] == 'audio') {
            final bytesSent = report.values['bytesSent'] ?? 0;
            if (bytesSent is int) {
              final delta = bytesSent - _lastBytesSent;
              _lastBytesSent = bytesSent;
              // > 500 bytes trong 300ms → đang nói (tương đương ~13kbps)
              if (delta > 500) speaking = true;
            }
          }

          // audioLevel > 0.05 → đang nói (0.01 quá nhạy, bắt cả noise)
          if (report.type == 'media-source' && report.values['kind'] == 'audio') {
            final audioLevel = report.values['audioLevel'];
            if (audioLevel is double && audioLevel > 0.05) speaking = true;
          }
        }

        if (speaking != _isSpeaking) {
          _isSpeaking = speaking;
          onStateChanged?.call();
          _syncPresenceWithSpeaking();
        }
      }).catchError((_) {});
    });
  }

  // Throttle: giới hạn tần suất gọi API — tối đa 1 lần mỗi 500ms
  DateTime _lastPresenceSync = DateTime(2000);

  Future<void> _syncPresenceWithSpeaking() async {
    if (!_isJoined) return;

    // Throttle: nếu chưa đủ 500ms kể từ lần gọi trước → bỏ qua
    final now = DateTime.now();
    if (now.difference(_lastPresenceSync).inMilliseconds < 500) return;
    _lastPresenceSync = now;

    try {
      await ApiClient.post(
        '/voice_signal.php',
        data: FormData.fromMap({
          'action': 'get_signals',
          'room_code': roomCode,
          'user': userName,
          'is_muted': _isMuted ? '1' : '0',
          'is_speaking': _isSpeaking ? '1' : '0',
        }),
      );
    } catch (_) {}
  }

  // ── Dispose ──────────────────────────────────────────────
  void dispose() {
    if (_isJoined) leave();
    _pollTimer?.cancel();
    _speakingTimer?.cancel();
    _presenceRefreshTimer?.cancel();
    _stopRttPolling();
  }
}

/// Voice participant state
class VoiceParticipantState {
  final String name;
  final String avatar;
  final bool isMuted;
  final bool isSpeaking;

  VoiceParticipantState({
    required this.name,
    this.avatar = '',
    this.isMuted = true,
    this.isSpeaking = false,
  });
}