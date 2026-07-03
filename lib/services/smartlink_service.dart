import 'package:flutter/material.dart';
import 'package:phimhay_app/screens/smartlink_interstitial_screen.dart';

class SmartlinkService {
  static DateTime? _lastAdShownAt;
  static const Duration _cooldown = Duration(minutes: 5);

  /// Kiểm tra xem có đang trong cooldown không
  static bool get isCooldownActive {
    if (_lastAdShownAt == null) return false;
    return DateTime.now().difference(_lastAdShownAt!) < _cooldown;
  }

  /// Ghi nhận đã xem ads — gọi khi user hoàn thành ads
  static void markAdShown() {
    _lastAdShownAt = DateTime.now();
    debugPrint('SmartLink: Ad shown, cooldown ${_cooldown.inMinutes}min started');
  }

  /// Hiển thị smartlink — nếu đang cooldown thì skip thẳng
  static void showSmartlinkBeforeAction(BuildContext context, {VoidCallback? onDone}) {
    // Đang cooldown → bỏ qua ads, chạy hành động luôn
    if (isCooldownActive) {
      debugPrint('SmartLink: Cooldown active, skipping ad');
      onDone?.call();
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SmartlinkInterstitialScreen(
          onComplete: () {
            onDone?.call();
          },
        ),
      ),
    );
  }
}
