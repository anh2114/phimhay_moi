import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:phimhay_app/screens/smartlink_interstitial_screen.dart';

class SmartlinkService {
  static DateTime? _lastAdShownAt;
  static const Duration _cooldown = Duration(seconds: 30);

  // 6 ad links
  static const List<String> _adLinks = [
    'https://omg10.com/4/11224550',
    'https://omg10.com/4/11235327',
    'https://omg10.com/4/11235328',
    'https://omg10.com/4/11235329',
    'https://omg10.com/4/11235330',
    'https://omg10.com/4/11235331',
  ];

  // Cache alive links
  static List<String> _aliveLinks = [];
  static DateTime? _lastCheckAt;
  static const Duration _checkInterval = Duration(minutes: 10);

  static bool get isCooldownActive {
    if (_lastAdShownAt == null) return false;
    return DateTime.now().difference(_lastAdShownAt!) < _cooldown;
  }

  static void markAdShown() {
    _lastAdShownAt = DateTime.now();
    debugPrint('SmartLink: Ad shown, cooldown ${_cooldown.inSeconds}s');
  }

  /// Health check — parallel HEAD request, timeout 3s/link
  static Future<void> checkLinks() async {
    if (_lastCheckAt != null && DateTime.now().difference(_lastCheckAt!) < _checkInterval) {
      return;
    }

    debugPrint('SmartLink: Checking ${_adLinks.length} links...');
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 3),
      receiveTimeout: const Duration(seconds: 3),
      followRedirects: true,
      maxRedirects: 3,
    ));

    final results = await Future.wait(
      _adLinks.map((url) async {
        try {
          final res = await dio.head(url);
          if (res.statusCode != null && res.statusCode! >= 200 && res.statusCode! < 400) {
            return url;
          }
        } catch (_) {}
        return null;
      }),
    );

    _aliveLinks = results.whereType<String>().toList();
    _lastCheckAt = DateTime.now();
    debugPrint('SmartLink: ${_aliveLinks.length}/${_adLinks.length} alive');
  }

  /// Random 1 link từ alive list
  static String? _pickRandomAlive() {
    if (_aliveLinks.isEmpty) return null;
    final idx = DateTime.now().millisecondsSinceEpoch % _aliveLinks.length;
    return _aliveLinks[idx];
  }

  /// Xóa link chết khỏi alive list
  static void removeDeadLink(String url) {
    _aliveLinks.remove(url);
    debugPrint('SmartLink: Removed dead, ${_aliveLinks.length} remaining');
  }

  /// Lấy link ads — null nếu tất cả chết hoặc đang cooldown
  static Future<String?> getAdLink() async {
    if (isCooldownActive) return null;
    await checkLinks();
    return _pickRandomAlive();
  }

  /// Show smartlink — returns true if ads shown, false if skipped
  static Future<bool> showSmartlinkBeforeAction(BuildContext context, {VoidCallback? onDone}) async {
    final link = await getAdLink();

    if (link == null) {
      onDone?.call();
      return false;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SmartlinkInterstitialScreen(
          adUrl: link,
          onComplete: () => onDone?.call(),
        ),
      ),
    );
    return true;
  }
}
