import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:startapp_sdk/startapp.dart';
import 'package:phimhay_app/services/ad_frequency_service.dart';

class StartAppAdService {
  static final StartAppSdk _sdk = StartAppSdk();
  static StartAppInterstitialAd? _interstitialAd;
  static StartAppRewardedVideoAd? _rewardedVideoAd;
  static final Map<String, StartAppNativeAd> _nativeAds = {};
  static bool _initialized = false;

  static StartAppSdk get sdk => _sdk;

  static void init() async {
    if (_initialized) return;
    _initialized = true;

    final platform = Platform.isIOS ? 'iOS' : (Platform.isAndroid ? 'Android' : 'Unknown');
    print('[StartApp] Initializing SDK on $platform...');

    await AdFrequencyService.init();

    try {
      // Disable test ads for production
      await _sdk.setTestAdsEnabled(false);
      print('[StartApp] Test ads disabled (production mode) on $platform');
      print('[StartApp] SDK initialized OK on $platform');
    } catch (e) {
      print('[StartApp] ERROR init on $platform: $e');
    }

    _preloadInterstitial();
    if (Platform.isIOS) {
      _preloadRewardedVideo();
    }
  }

  static void _preloadInterstitial() {
    final platform = Platform.isIOS ? 'iOS' : (Platform.isAndroid ? 'Android' : 'Unknown');
    print('[StartApp] Loading interstitial on $platform...');
    _sdk.loadInterstitialAd(
      onAdDisplayed: () {
        print('[StartApp] Interstitial AD_DISPLAYED');
      },
      onAdNotDisplayed: () {
        print('[StartApp] Interstitial AD_NOT_DISPLAYED');
        _interstitialAd?.dispose();
        _interstitialAd = null;
      },
      onAdHidden: () {
        print('[StartApp] Interstitial AD_HIDDEN');
        _interstitialAd?.dispose();
        _interstitialAd = null;
        _preloadInterstitial();
      },
      onAdClicked: () {
        print('[StartApp] Interstitial AD_CLICKED');
      },
    ).then((ad) {
      _interstitialAd = ad;
      print('[StartApp] Interstitial loaded OK on $platform');
    }).onError((err, stack) {
      print('[StartApp] Interstitial FAILED: $err');
      _interstitialAd = null;
    });
  }

  static void _preloadRewardedVideo() {
    print('[StartApp] Loading rewarded video on iOS...');
    _sdk.loadRewardedVideoAd(
      onAdNotDisplayed: () {
        print('[StartApp] Rewarded AD_NOT_DISPLAYED');
        _rewardedVideoAd?.dispose();
        _rewardedVideoAd = null;
      },
      onAdHidden: () {
        print('[StartApp] Rewarded AD_HIDDEN');
        _rewardedVideoAd?.dispose();
        _rewardedVideoAd = null;
        _preloadRewardedVideo();
      },
      onVideoCompleted: () {
        print('[StartApp] Rewarded VIDEO_COMPLETED - reward earned');
      },
    ).then((ad) {
      _rewardedVideoAd = ad;
      print('[StartApp] Rewarded video loaded OK on iOS');
    }).onError((err, stack) {
      print('[StartApp] Rewarded video FAILED: $err');
      _rewardedVideoAd = null;
    });
  }

  // ── Native Ad ──────────────────────────────────────
  static void loadNativeAd(String tag) {
    if (_nativeAds.containsKey(tag)) return;
    final platform = Platform.isIOS ? 'iOS' : (Platform.isAndroid ? 'Android' : 'Unknown');
    print('[StartApp] Loading native ad: $tag on $platform');
    _sdk.loadNativeAd(
      onAdImpression: () {},
      onAdClicked: () {},
    ).then((ad) {
      _nativeAds[tag] = ad;
      print('[StartApp] Native loaded: $tag');
    }).onError((err, stack) {
      print('[StartApp] Native FAILED: $tag $err');
    });
  }

  static StartAppNativeAd? getNativeAd(String tag) {
    return _nativeAds[tag];
  }

  static void disposeNativeAd(String tag) {
    _nativeAds[tag]?.dispose();
    _nativeAds.remove(tag);
  }

  // ── Frequency-capped interstitial ──────────────────
  static void showInterstitialIfAllowed(BuildContext context, {VoidCallback? onDone}) {
    if (!AdFrequencyService.canShowInterstitial()) {
      print('[StartApp] Interstitial blocked by frequency cap (${AdFrequencyService.remainingAds} remaining)');
      onDone?.call();
      return;
    }
    if (_interstitialAd != null) {
      print('[StartApp] Showing frequency-capped interstitial...');
      final ad = _interstitialAd;
      _interstitialAd = null;
      AdFrequencyService.recordInterstitialShow();
      ad!.show().then((shown) {
        print('[StartApp] Frequency interstitial shown=$shown');
        if (shown) {
          _preloadInterstitial();
          onDone?.call();
        } else {
          onDone?.call();
        }
      }).onError((err, stack) {
        print('[StartApp] Frequency interstitial FAILED: $err');
        onDone?.call();
      });
    } else {
      print('[StartApp] No interstitial ready for frequency cap');
      onDone?.call();
    }
  }

  // ── Pre-watch flow ─────────────────────────────────
  static void showBeforeWatch(BuildContext context, Function onReady) {
    print('[StartApp] showBeforeWatch called');
    print('[StartApp] interstitialAd=${_interstitialAd != null ? "READY" : "null"}');
    _showInterstitialAd(context, onReady);
  }

  // Show rewarded ad (iOS - higher eCPM)
  static void showRewardedBeforeAction(BuildContext context, {VoidCallback? onReward, VoidCallback? onDone}) {
    if (Platform.isIOS && _rewardedVideoAd != null) {
      print('[StartApp] Showing rewarded video on iOS...');
      final ad = _rewardedVideoAd;
      _rewardedVideoAd = null;
      ad!.show().then((_) {
        print('[StartApp] Rewarded video shown on iOS');
        onReward?.call();
        onDone?.call();
        _preloadRewardedVideo();
      }).onError((err, stack) {
        print('[StartApp] Rewarded video show FAILED: $err');
        // Fallback to interstitial
        showInterstitialIfAllowed(context, onDone: onDone);
      });
    } else {
      // Fallback to interstitial
      print('[StartApp] No rewarded video available, using interstitial');
      showBeforeWatch(context, (onDone ?? () {}) as Function);
    }
  }

  static void _showInterstitialAd(BuildContext context, Function onReady) {
    if (_interstitialAd != null) {
      print('[StartApp] Showing interstitial...');
      final ad = _interstitialAd;
      _interstitialAd = null;
      ad!.show().then((shown) {
        print('[StartApp] Interstitial shown=$shown');
        if (shown) {
          _preloadInterstitial();
          onReady();
        } else {
          _showPreRoll(context, onReady);
        }
      }).onError((err, stack) {
        print('[StartApp] Interstitial show FAILED: $err');
        _showPreRoll(context, onReady);
      });
      return;
    }
    print('[StartApp] No interstitial available, showing pre-roll only');
    _showPreRoll(context, onReady);
  }

  static void _showPreRoll(BuildContext context, Function onReady) {
    Navigator.push(context, PageRouteBuilder(
      opaque: true,
      barrierDismissible: false,
      pageBuilder: (_, __, ___) => _PreRollAdWidget(
          onComplete: () {
        Navigator.pop(context);
        onReady();
      }),
      transitionsBuilder: (_, a, __, child) =>
          FadeTransition(opacity: a, child: child),
    ));
  }

  // ── Debug Info ─────────────────────────────────────
  static Future<Map<String, dynamic>> getDebugInfo() async {
    final platform = Platform.isIOS ? 'iOS' : (Platform.isAndroid ? 'Android' : 'Unknown');
    return {
      'platform': platform,
      'initialized': _initialized,
      'interstitialReady': _interstitialAd != null,
      'rewardedReady': _rewardedVideoAd != null,
      'nativeAdsCount': _nativeAds.length,
      'appId': Platform.isIOS ? '206259683' : 'Android App ID',
    };
  }
}

class _PreRollAdWidget extends StatefulWidget {
  final VoidCallback onComplete;
  const _PreRollAdWidget({required this.onComplete});

  @override
  State<_PreRollAdWidget> createState() => _PreRollAdWidgetState();
}

class _PreRollAdWidgetState extends State<_PreRollAdWidget>
    with SingleTickerProviderStateMixin {
  late Timer _timer;
  int _seconds = 5;
  bool _canSkip = false;
  bool _disposed = false;
  late AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
        vsync: this, duration: const Duration(seconds: 5))
      ..forward();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_disposed) {
        t.cancel();
        return;
      }
      setState(() {
        _seconds--;
        if (_seconds <= 0) {
          _canSkip = true;
          t.cancel();
        }
      });
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
        color: Colors.black,
        child: Stack(fit: StackFit.expand, children: [
          const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.ad_units, color: Colors.amber, size: 64),
            SizedBox(height: 16),
            Text('QUẢNG CÁO',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ])),
          Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 16,
              child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                      color: Colors.amber.shade700,
                      borderRadius: BorderRadius.circular(4)),
                  child: const Text('QUẢNG CÁO',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1)))),
          Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              right: 16,
              child: _canSkip
                  ? GestureDetector(
                      onTap: widget.onComplete,
                      child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(4),
                              border:
                                  Border.all(color: Colors.white54, width: 1)),
                          child: const Text('Bỏ qua ▸',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600))))
                  : Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4)),
                      child: Text('Bỏ qua sau ${_seconds}s',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)))),
          Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedBuilder(
                  animation: _anim,
                  builder: (_, __) => LinearProgressIndicator(
                      value: _anim.value,
                      backgroundColor: Colors.white24,
                      valueColor:
                          const AlwaysStoppedAnimation(Colors.amber),
                      minHeight: 3))),
        ]));
  }
}
