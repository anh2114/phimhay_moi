import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:phimhay_app/services/ad_frequency_service.dart';

class AppLovinAdService {
  static bool _initialized = false;
  static bool _sdkReady = false;
  static bool get isReady => _sdkReady;

  // Your AppLovin SDK Key
  static const String _sdkKey = '3d38b6d1147aafeef29a80bd9d3c675598ccd6d705c8d51';

  // Ad Unit IDs — replace with your actual IDs from AppLovin dashboard
  static const String _interstitialAdUnitId = Platform.isIOS
      ? 'YOUR_IOS_INTERSTITIAL_AD_UNIT_ID'
      : 'YOUR_ANDROID_INTERSTITIAL_AD_UNIT_ID';
  static const String _bannerAdUnitId = Platform.isIOS
      ? 'YOUR_IOS_BANNER_AD_UNIT_ID'
      : 'YOUR_ANDROID_BANNER_AD_UNIT_ID';
  static const String _rewardedAdUnitId = Platform.isIOS
      ? 'YOUR_IOS_REWARDED_AD_UNIT_ID'
      : 'YOUR_ANDROID_REWARDED_AD_UNIT_ID';

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final platform = Platform.isIOS ? 'iOS' : 'Android';
    print('[AppLovin] Initializing on $platform...');

    await AdFrequencyService.init();

    MaxConfiguration? config = await AppLovinMAX.initialize(_sdkKey);
    if (config != null) {
      _sdkReady = true;
      print('[AppLovin] SDK initialized OK on $platform');
      print('[AppLovin] SDK version: ${config.sdkVersion}');
      _loadInterstitial();
      _loadRewarded();
    } else {
      print('[AppLovin] SDK init FAILED on $platform');
    }
  }

  // ── Interstitial ──────────────────────────────────
  static bool _interstitialReady = false;

  static void _loadInterstitial() {
    print('[AppLovin] Loading interstitial...');
    AppLovinMAX.loadInterstitial(_interstitialAdUnitId);
    AppLovinMAX.setInterstitialListener(InterstitialListener(
      onInterstitialLoaded: (ad) {
        _interstitialReady = true;
        print('[AppLovin] Interstitial loaded');
      },
      onInterstitialLoadFailed: (adUnitId, error) {
        _interstitialReady = false;
        print('[AppLovin] Interstitial load FAILED: ${error.message}');
        // Retry after 30s
        Future.delayed(const Duration(seconds: 30), _loadInterstitial);
      },
      onInterstitialDisplayed: (ad) {
        print('[AppLovin] Interstitial displayed');
        _interstitialReady = false;
        _loadInterstitial();
      },
      onInterstitialDisplayFailed: (ad, error) {
        print('[AppLovin] Interstitial display FAILED: ${error.message}');
        _loadInterstitial();
      },
      onInterstitialHidden: (ad) {
        print('[AppLovin] Interstitial hidden');
        _loadInterstitial();
      },
      onInterstitialClicked: (ad) {
        print('[AppLovin] Interstitial clicked');
      },
      onInterstitialRevenuePaid: (ad, revenue) {
        print('[AppLovin] Interstitial revenue: \$revenue');
      },
    ));
  }

  static void showInterstitialIfAllowed(BuildContext context, {VoidCallback? onDone}) {
    if (!AdFrequencyService.canShowInterstitial()) {
      onDone?.call();
      return;
    }
    if (_interstitialReady) {
      AdFrequencyService.recordInterstitialShow();
      AppLovinMAX.showInterstitial(_interstitialAdUnitId);
      onDone?.call();
    } else {
      print('[AppLovin] Interstitial not ready');
      onDone?.call();
    }
  }

  // ── Rewarded ──────────────────────────────────────
  static bool _rewardedReady = false;

  static void _loadRewarded() {
    print('[AppLovin] Loading rewarded...');
    AppLovinMAX.loadRewardedAd(_rewardedAdUnitId);
    AppLovinMAX.setRewardedListener(RewardedListener(
      onRewardedAdLoaded: (ad) {
        _rewardedReady = true;
        print('[AppLovin] Rewarded loaded');
      },
      onRewardedAdLoadFailed: (adUnitId, error) {
        _rewardedReady = false;
        print('[AppLovin] Rewarded load FAILED: ${error.message}');
        Future.delayed(const Duration(seconds: 30), _loadRewarded);
      },
      onRewardedAdDisplayed: (ad) {
        print('[AppLovin] Rewarded displayed');
        _rewardedReady = false;
        _loadRewarded();
      },
      onRewardedAdDisplayFailed: (ad, error) {
        print('[AppLovin] Rewarded display FAILED: ${error.message}');
        _loadRewarded();
      },
      onRewardedAdHidden: (ad) {
        print('[AppLovin] Rewarded hidden');
        _loadRewarded();
      },
      onRewardedAdClicked: (ad) {
        print('[AppLovin] Rewarded clicked');
      },
      onRewardedAdReceivedReward: (ad, reward) {
        print('[AppLovin] Rewarded received: ${reward.amount} ${reward.label}');
      },
      onRewardedAdRevenuePaid: (ad, revenue) {
        print('[AppLovin] Rewarded revenue: \$revenue');
      },
    ));
  }

  static void showRewardedIfAllowed(BuildContext context, {VoidCallback? onReward, VoidCallback? onDone}) {
    if (_rewardedReady) {
      AppLovinMAX.showRewardedAd(_rewardedAdUnitId);
      onDone?.call();
    } else {
      print('[AppLovin] Rewarded not ready');
      onDone?.call();
    }
  }

  // ── Pre-watch flow ────────────────────────────────
  static void showBeforeWatch(BuildContext context, Function onReady) {
    print('[AppLovin] showBeforeWatch called, ready=$_interstitialReady');
    showInterstitialIfAllowed(context, onDone: () => onReady());
  }

  // ── Banner ────────────────────────────────────────
  static String get bannerAdUnitId => _bannerAdUnitId;
}
