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
    await AdFrequencyService.init();

    try {
      // Set callbacks before initialization
      Appodeal.setBannerCallbacks(
        onBannerLoaded: (isPrecache) {
          _sdkReady = true;
        },
        onBannerFailedToLoad: () {
        },
        onBannerShown: () {
        },
        onBannerShowFailed: () {
        },
        onBannerClicked: () {
        },
        onBannerExpired: () {
        },
      );

      Appodeal.setInterstitialCallbacks(
        onInterstitialLoaded: (isPrecache) {
        },
        onInterstitialFailedToLoad: () {
        },
        onInterstitialShown: () {
        },
        onInterstitialShowFailed: () {
        },
        onInterstitialClosed: () {
          loadInterstitial();
        },
        onInterstitialExpired: () {
        },
      );

      Appodeal.setRewardedVideoCallbacks(
        onRewardedVideoLoaded: (isPrecache) {
        },
        onRewardedVideoFailedToLoad: () {
        },
        onRewardedVideoShown: () {
        },
        onRewardedVideoFinished: (amount, reward) {
        },
        onRewardedVideoClosed: (isFinished) {
          loadRewarded();
        },
        onRewardedVideoExpired: () {
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
          }
          _sdkReady = true;
          loadInterstitial();
          loadRewarded();
        },
      );
    } catch (e) {
      _sdkReady = false;
    }
  }

  static void loadInterstitial() {
    if (!Platform.isIOS) return;
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
      } else {
      }
      onDone?.call();
    }).catchError((e) {
      onDone?.call();
    });
  }

  static void loadRewarded() {
    if (!Platform.isIOS) return;
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
      } else {
      }
      onDone?.call();
    }).catchError((e) {
      onDone?.call();
    });
  }

  static void loadBanner() {
    if (!Platform.isIOS) return;
    Appodeal.cache(AppodealAdType.Banner);
  }

  static Future<bool> showBanner() async {
    if (!Platform.isIOS) return false;
    try {
      await init();
      final canShow = await Appodeal.canShow(AppodealAdType.Banner);
      if (canShow) {
        Appodeal.show(AppodealAdType.BannerBottom);
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  static Future<void> hideBanner() async {
    if (!Platform.isIOS) return;
    try {
      Appodeal.hide(AppodealAdType.BannerBottom);
    } catch (e) {
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
    showInterstitialIfAllowed(context, onDone: () => onReady());
  }

  // Show rewarded ad - higher eCPM than interstitial
  static void showRewardedBeforeAction(BuildContext context, {VoidCallback? onReward, VoidCallback? onDone}) {
    if (!Platform.isIOS) {
      onDone?.call();
      return;
    }
    init().then((_) async {
      final canShow = await Appodeal.canShow(AppodealAdType.RewardedVideo);
      if (canShow) {
        Appodeal.show(AppodealAdType.RewardedVideo);
        onReward?.call();
      } else {
        showInterstitialIfAllowed(context, onDone: onDone);
        return;
      }
      onDone?.call();
    }).catchError((e) {
      showInterstitialIfAllowed(context, onDone: onDone);
    });
  }

  // Preload all ad types
  static void preloadAll() {
    if (!Platform.isIOS) return;
    loadBanner();
    loadInterstitial();
    loadRewarded();
  }
}
