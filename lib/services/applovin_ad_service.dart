import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:stack_appodeal_flutter/stack_appodeal_flutter.dart';
import 'package:phimhay_app/services/ad_frequency_service.dart';

class AppLovinAdService {
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
      // Set callbacks before initialization
      Appodeal.setBannerCallbacks(
        onBannerLoaded: (isPrecache) {
          print('[Appodeal] Banner loaded, precache=$isPrecache');
          _sdkReady = true;
        },
        onBannerFailedToLoad: () {
          print('[Appodeal] Banner failed to load');
        },
        onBannerShown: () {
          print('[Appodeal] Banner shown');
        },
        onBannerShowFailed: () {
          print('[Appodeal] Banner show failed');
        },
        onBannerClicked: () {
          print('[Appodeal] Banner clicked');
        },
        onBannerExpired: () {
          print('[Appodeal] Banner expired');
        },
      );

      Appodeal.setInterstitialCallbacks(
        onInterstitialLoaded: (isPrecache) {
          print('[Appodeal] Interstitial loaded, precache=$isPrecache');
        },
        onInterstitialFailedToLoad: () {
          print('[Appodeal] Interstitial failed to load');
        },
        onInterstitialShown: () {
          print('[Appodeal] Interstitial shown');
        },
        onInterstitialShowFailed: () {
          print('[Appodeal] Interstitial show failed');
        },
        onInterstitialClosed: () {
          print('[Appodeal] Interstitial closed');
          loadInterstitial();
        },
        onInterstitialExpired: () {
          print('[Appodeal] Interstitial expired');
        },
      );

      Appodeal.setRewardedVideoCallbacks(
        onRewardedVideoLoaded: (isPrecache) {
          print('[Appodeal] Rewarded loaded, precache=$isPrecache');
        },
        onRewardedVideoFailedToLoad: () {
          print('[Appodeal] Rewarded failed to load');
        },
        onRewardedVideoShown: () {
          print('[Appodeal] Rewarded shown');
        },
        onRewardedVideoFinished: (amount, reward) {
          print('[Appodeal] Rewarded finished: $amount $reward');
        },
        onRewardedVideoClosed: (isFinished) {
          print('[Appodeal] Rewarded closed, finished=$isFinished');
          loadRewarded();
        },
        onRewardedVideoExpired: () {
          print('[Appodeal] Rewarded expired');
        },
      );

      // Initialize Appodeal
      await Appodeal.initialize(
        appKey: _appKey,
        adTypes: [
          AppodealAdType.Interstitial,
          AppodealAdType.RewardedVideo,
          AppodealAdType.Banner,
        ],
        onInitializationFinished: (errors) {
          if (errors != null && errors.isNotEmpty) {
            print('[Appodeal] Init errors: $errors');
          }
          _sdkReady = true;
          print('[Appodeal] SDK initialized on iOS');
          loadInterstitial();
          loadRewarded();
        },
      );
    } catch (e) {
      print('[Appodeal] Init FAILED: $e');
      _sdkReady = false;
    }
  }

  static void loadInterstitial() {
    if (!Platform.isIOS) return;
    print('[Appodeal] Loading interstitial...');
    Appodeal.cache(AppodealAdType.Interstitial);
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
    init().then((_) async {
      final canShow = await Appodeal.canShow(AppodealAdType.Interstitial);
      if (canShow) {
        Appodeal.show(AppodealAdType.Interstitial);
        AdFrequencyService.recordInterstitialShow();
        print('[Appodeal] Interstitial shown');
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
    Appodeal.cache(AppodealAdType.RewardedVideo);
  }

  static void showRewardedIfAllowed(BuildContext context, {VoidCallback? onReward, VoidCallback? onDone}) {
    if (!Platform.isIOS) {
      onDone?.call();
      return;
    }
    init().then((_) async {
      final canShow = await Appodeal.canShow(AppodealAdType.RewardedVideo);
      if (canShow) {
        Appodeal.show(AppodealAdType.RewardedVideo);
        onReward?.call();
        print('[Appodeal] Rewarded shown + reward earned');
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
    Appodeal.cache(AppodealAdType.Banner);
  }

  static Future<bool> showBanner() async {
    if (!Platform.isIOS) return false;
    try {
      await init();
      final canShow = await Appodeal.canShow(AppodealAdType.Banner);
      if (canShow) {
        Appodeal.show(AppodealAdType.BannerBottom);
        print('[Appodeal] Banner shown');
        return true;
      }
      print('[Appodeal] Banner not ready');
      return false;
    } catch (e) {
      print('[Appodeal] Banner show FAILED: $e');
      return false;
    }
  }

  static Future<void> hideBanner() async {
    if (!Platform.isIOS) return;
    try {
      Appodeal.hide(AppodealAdType.BannerBottom);
      print('[Appodeal] Banner hidden');
    } catch (e) {
      print('[Appodeal] Banner hide FAILED: $e');
    }
  }

  static Future<bool> isBannerLoaded() async {
    if (!Platform.isIOS) return false;
    try {
      return await Appodeal.isLoaded(AppodealAdType.Banner);
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> getDebugInfo() async {
    if (!Platform.isIOS) return null;
    try {
      final canShow = await Appodeal.canShow(AppodealAdType.Banner);
      final isLoaded = await Appodeal.isLoaded(AppodealAdType.Banner);
      return {
        'bannerCanShow': canShow,
        'bannerIsLoaded': isLoaded,
        'sdkReady': _sdkReady,
      };
    } catch (_) {
      return null;
    }
  }

  static void showBeforeWatch(BuildContext context, Function onReady) {
    print('[Appodeal] showBeforeWatch called');
    showInterstitialIfAllowed(context, onDone: () => onReady());
  }
}
