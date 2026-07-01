import 'package:flutter/material.dart';
import 'package:phimhay_app/screens/smartlink_interstitial_screen.dart';

class SmartlinkService {
  static void showSmartlinkBeforeAction(BuildContext context, {VoidCallback? onDone}) {
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
