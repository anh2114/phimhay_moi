class UnityAdService {
  static bool get isReady => false;

  static Future<void> init() async {
    print('[UnityAds] Disabled - plugin removed');
  }

  static void showAd({required Function onDone}) {
    print('[UnityAds] Disabled - skipping ad');
    onDone();
  }
}
