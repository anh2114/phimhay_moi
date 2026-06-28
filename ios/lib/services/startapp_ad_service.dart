import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:startapp_sdk/startapp.dart';
import 'package:phimhay_app/services/ad_frequency_service.dart';
import 'package:phimhay_app/services/applovin_ad_service.dart';

class StartAppAdService {
  static final StartAppSdk _sdk = StartAppSdk();
  static StartAppInterstitialAd? _interstitialAd;
  static final Map<String, StartAppNativeAd> _nativeAds = {};
  static bool _initialized = false;

  static StartAppSdk get sdk => _sdk;

  static void init() async {
    if (_initialized) return;
    _initialized = true;

    if (Platform.isIOS) {
      print('[StartApp] Disabled on iOS, initializing Appodeal instead...');
      await AppLovinAdService.init();
      return;
    }

    await AdFrequencyService.init();
    final platform = Platform.isAndroid ? 'Android' : 'Unknown';
    print('[StartApp] Initializing SDK on $platform...');
    try {
      await _sdk.setTestAdsEnabled(false);
      print('[StartApp] SDK initialized OK on $platform');
    } catch (e) {
      print('[StartApp] ERROR init on $platform: $e');
    }
    _preloadInterstitial();
  }

  static void _preloadInterstitial() {
    if (Platform.isIOS) return;
    final platform = Platform.isAndroid ? 'Android' : 'Unknown';
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
      print('[StartApp] Interstitial loaded OK');
    }).onError((err, stack) {
      print('[StartApp] Interstitial FAILED: $err');
      _interstitialAd = null;
    });
  }

  // ── Native Ad ──────────────────────────────────────
  static void loadNativeAd(String tag) {
    if (Platform.isIOS) return;
    if (_nativeAds.containsKey(tag)) return;
    final platform = Platform.isAndroid ? 'Android' : 'Unknown';
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
    if (Platform.isIOS) return null;
    return _nativeAds[tag];
  }

  static void disposeNativeAd(String tag) {
    if (Platform.isIOS) return;
    _nativeAds[tag]?.dispose();
    _nativeAds.remove(tag);
  }

  // ── Frequency-capped interstitial ──────────────────
  static void showInterstitialIfAllowed(BuildContext context, {VoidCallback? onDone}) {
    if (Platform.isIOS) {
      AppLovinAdService.showInterstitialIfAllowed(context, onDone: onDone);
      return;
    }
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
    if (Platform.isIOS) {
      AppLovinAdService.showBeforeWatch(context, onReady);
      return;
    }
    print('[StartApp] showBeforeWatch called');
    print('[StartApp] interstitialAd=${_interstitialAd != null ? "READY" : "null"}');
    _showInterstitialAd(context, onReady);
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
