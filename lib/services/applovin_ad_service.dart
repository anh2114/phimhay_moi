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

  static const String _appKey = '3d38b6d1147aafeef29a80bd9d3c675598ccd6d705c8d51';

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final platform = Platform.isIOS ? 'iOS' : 'Android';
    print('[Appodeal] Initializing on $platform...');

    await AdFrequencyService.init();

    try {
      final result = await _channel.invokeMethod('initialize', {
        'appKey': _appKey,
      });
      _sdkReady = result == true;
      print('[Appodeal] SDK initialized: $_sdkReady on $platform');
      if (_sdkReady) {
        loadInterstitial();
        loadRewarded();
      }
    } catch (e) {
      print('[Appodeal] Init FAILED: $e');
    }
  }

  static void loadInterstitial() {
    print('[Appodeal] Loading interstitial...');
    _channel.invokeMethod('loadInterstitial').then((_) {
      print('[Appodeal] Interstitial load requested');
    }).catchError((e) {
      print('[Appodeal] Interstitial load FAILED: $e');
      Future.delayed(const Duration(seconds: 30), loadInterstitial);
    });
  }

  static void showInterstitialIfAllowed(BuildContext context, {VoidCallback? onDone}) {
    if (!AdFrequencyService.canShowInterstitial()) {
      onDone?.call();
      return;
    }
    _channel.invokeMethod('showInterstitial').then((shown) {
      if (shown == true) {
        AdFrequencyService.recordInterstitialShow();
        print('[Appodeal] Interstitial shown');
        loadInterstitial();
      }
      onDone?.call();
    }).catchError((e) {
      print('[Appodeal] Interstitial show FAILED: $e');
      onDone?.call();
    });
  }

  static void loadRewarded() {
    print('[Appodeal] Loading rewarded...');
    _channel.invokeMethod('loadRewarded').then((_) {
      print('[Appodeal] Rewarded load requested');
    }).catchError((e) {
      print('[Appodeal] Rewarded load FAILED: $e');
      Future.delayed(const Duration(seconds: 30), loadRewarded);
    });
  }

  static void showRewardedIfAllowed(BuildContext context, {VoidCallback? onReward, VoidCallback? onDone}) {
    _channel.invokeMethod('showRewarded').then((rewarded) {
      if (rewarded == true) {
        print('[Appodeal] Rewarded shown + reward earned');
        onReward?.call();
        loadRewarded();
      }
      onDone?.call();
    }).catchError((e) {
      print('[Appodeal] Rewarded show FAILED: $e');
      onDone?.call();
    });
  }

  static void loadBanner() {
    print('[Appodeal] Loading banner...');
    _channel.invokeMethod('loadBanner').then((_) {
      print('[Appodeal] Banner load requested');
    }).catchError((e) {
      print('[Appodeal] Banner load FAILED: $e');
    });
  }

  static void showBeforeWatch(BuildContext context, Function onReady) {
    print('[Appodeal] showBeforeWatch called');
    showInterstitialIfAllowed(context, onDone: () => onReady());
  }
}
