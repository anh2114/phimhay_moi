import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phimhay_app/services/ad_frequency_service.dart';

class AppLovinAdService {
  static const MethodChannel _channel = MethodChannel('com.xiaofilm/appodeal');
  static bool _initialized = false;
  static bool _sdkReady = false;
  static bool get isReady => _sdkReady;

  static const String _appKey = '3d38b6d1147aafee7f29a80bd9d3c675598ccd6d705c8d51';

  static Future<void> init() async {
    if (!Platform.isIOS) return;
    if (_initialized) return;
    _initialized = true;

    print('[Appodeal] Initializing on iOS...');

    await AdFrequencyService.init();

    try {
      final result = await _channel.invokeMethod('initialize', {
        'appKey': _appKey,
      });
      _sdkReady = result == true;
      print('[Appodeal] SDK initialized: $_sdkReady on iOS');
      if (_sdkReady) {
        loadInterstitial();
        loadRewarded();
        loadBanner();
      }
    } catch (e) {
      print('[Appodeal] Init FAILED: $e');
      _sdkReady = false;
    }
  }

  static void loadInterstitial() {
    if (!Platform.isIOS) return;
    print('[Appodeal] Loading interstitial...');
    _channel.invokeMethod('loadInterstitial').then((_) {
      print('[Appodeal] Interstitial load requested');
    }).catchError((e) {
      print('[Appodeal] Interstitial load FAILED: $e');
      return null;
    });
  }

  static void showInterstitialIfAllowed(BuildContext context, {VoidCallback? onDone}) {
    if (!Platform.isIOS) {
      onDone?.call();
      return;
    }
    if (!AdFrequencyService.canShowInterstitial()) {
      onDone?.call();
      return;
    }
    init().then((_) {
      return _channel.invokeMethod('showInterstitial');
    }).then((shown) {
      if (shown == true) {
        AdFrequencyService.recordInterstitialShow();
        print('[Appodeal] Interstitial shown');
        loadInterstitial();
      } else {
        print('[Appodeal] Interstitial not ready / not shown');
      }
      onDone?.call();
    }).catchError((e) {
      print('[Appodeal] Interstitial show FAILED: $e');
      onDone?.call();
      return null;
    });
  }

  static void loadRewarded() {
    if (!Platform.isIOS) return;
    print('[Appodeal] Loading rewarded...');
    _channel.invokeMethod('loadRewarded').then((_) {
      print('[Appodeal] Rewarded load requested');
    }).catchError((e) {
      print('[Appodeal] Rewarded load FAILED: $e');
      return null;
    });
  }

  static void showRewardedIfAllowed(BuildContext context, {VoidCallback? onReward, VoidCallback? onDone}) {
    if (!Platform.isIOS) {
      onDone?.call();
      return;
    }
    init().then((_) {
      return _channel.invokeMethod('showRewarded');
    }).then((rewarded) {
      if (rewarded == true) {
        print('[Appodeal] Rewarded shown + reward earned');
        onReward?.call();
        loadRewarded();
      } else {
        print('[Appodeal] Rewarded not ready / not shown');
      }
      onDone?.call();
    }).catchError((e) {
      print('[Appodeal] Rewarded show FAILED: $e');
      onDone?.call();
      return null;
    });
  }

  static void loadBanner() {
    if (!Platform.isIOS) return;
    print('[Appodeal] Loading banner...');
    _channel.invokeMethod('loadBanner').then((_) {
      print('[Appodeal] Banner load requested');
    }).catchError((e) {
      print('[Appodeal] Banner load FAILED: $e');
      return null;
    });
  }

  static Future<bool> showBanner() async {
    if (!Platform.isIOS) return false;
    try {
      await init();
      final shown = await _channel.invokeMethod('showBanner');
      print('[Appodeal] Banner show result=$shown');
      return shown == true;
    } catch (e) {
      print('[Appodeal] Banner show FAILED: $e');
      return false;
    }
  }

  static Future<void> hideBanner() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('hideBanner');
      print('[Appodeal] Banner hidden');
    } catch (e) {
      print('[Appodeal] Banner hide FAILED: $e');
    }
  }

  static void showBeforeWatch(BuildContext context, Function onReady) {
    print('[Appodeal] showBeforeWatch called');
    showInterstitialIfAllowed(context, onDone: () => onReady());
  }
}
