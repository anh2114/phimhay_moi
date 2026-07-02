class UnityAdService {
  static bool get isReady => false;

  static Future<void> init() async {
  }

  static void showAd({required Function onDone}) {
    onDone();
  }
}
