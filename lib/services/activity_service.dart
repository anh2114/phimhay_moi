import 'dart:async';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/api_client.dart';

class ActivityService {
  static Timer? _heartbeatTimer;
  static String _deviceId = '';
  static String _deviceModel = '';
  static String _osVersion = '';
  static String _appVersion = '';
  static String _platform = '';
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _appVersion = packageInfo.version;

      if (Platform.isIOS) {
        _platform = 'ios';
        final iosInfo = await DeviceInfoPlugin().iosInfo;
        _deviceId = iosInfo.identifierForVendor ?? '';
        _deviceModel = iosInfo.name;
        _osVersion = '${iosInfo.systemName} ${iosInfo.systemVersion}';
      } else if (Platform.isAndroid) {
        _platform = 'android';
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        _deviceId = androidInfo.id;
        _deviceModel = '${androidInfo.brand} ${androidInfo.model}';
        _osVersion = 'Android ${androidInfo.version.release}';
      }
    } catch (_) {}

    _startHeartbeat();
  }

  static void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _sendHeartbeat();
    });
    _sendHeartbeat();
  }

  static void _sendHeartbeat({Map<String, dynamic>? watching}) {
    if (ApiClient.dio == null) return;

    final data = <String, dynamic>{
      'device_id': _deviceId,
      'device_model': _deviceModel,
      'os_version': _osVersion,
      'app_version': _appVersion,
      'platform': _platform,
    };

    if (watching != null) {
      data.addAll(watching);
    }

    ApiClient.post('/activity_heartbeat.php', data: data).catchError((_) => null);
  }

  static void reportWatching({
    required int movieId,
    int? episodeId,
    String? epSlug,
    int serverIdx = 0,
    int position = 0,
    int duration = 0,
    String? sourceType,
  }) {
    _sendHeartbeat(watching: {
      'movie_id': movieId,
      if (episodeId != null) 'episode_id': episodeId,
      if (epSlug != null) 'ep_slug': epSlug,
      'server_idx': serverIdx,
      'position': position,
      'duration': duration,
      if (sourceType != null) 'source_type': sourceType,
    });
  }

  static void stopWatching() {
    _sendHeartbeat(watching: {
      'movie_id': 0,
    });
  }

  static void dispose() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }
}
