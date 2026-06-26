import 'package:shared_preferences/shared_preferences.dart';

class AdFrequencyService {
  static int _sessionCount = 0;
  static int _lastShowTime = 0;
  static const int _maxPerSession = 4;
  static const int _cooldownMs = 30000;

  static Future<void> init() async {
    _sessionCount = 0;
    _lastShowTime = 0;
  }

  static bool canShowInterstitial() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _lastShowTime;
    return _sessionCount < _maxPerSession && elapsed >= _cooldownMs;
  }

  static void recordInterstitialShow() {
    _sessionCount++;
    _lastShowTime = DateTime.now().millisecondsSinceEpoch;
  }

  static int get remainingAds => _maxPerSession - _sessionCount;
}
