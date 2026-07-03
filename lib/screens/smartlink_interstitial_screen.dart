import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class SmartlinkInterstitialScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const SmartlinkInterstitialScreen({super.key, required this.onComplete});

  @override
  State<SmartlinkInterstitialScreen> createState() => _SmartlinkInterstitialScreenState();
}

class _SmartlinkInterstitialScreenState extends State<SmartlinkInterstitialScreen> {
  static const String _primaryUrl = 'https://omg10.com/4/11224550';
  static const String _fallbackUrl = 'https://omg10.com/4/11224692';

  // Tracking URLs — thay bằng URL thật từ SmartLink dashboard
  static const String _impressionUrl = 'https://omg10.com/track/impression?ad=11224550';
  static const String _clickUrl = 'https://omg10.com/track/click?ad=11224550';

  InAppWebViewController? _webController;
  String _currentUrl = _primaryUrl;

  // States
  bool _isLoading = true;
  bool _adLoaded = false;       // Ads đã load xong + có nội dung
  bool _canProceed = false;     // User có thể bấm "Xem phim"
  bool _navigated = false;
  bool _triedFallback = false;
  bool _loadFailed = false;     // Ads load hoàn toàn thất bại

  // Countdown — chỉ chạy SAU KHI ads load xong
  int _countdown = 0;
  static const int _countdownDuration = 15;
  Timer? _countdownTimer;

  // Content check
  static const int _maxCheckAttempts = 10;

  // Tracking
  int _adViewDuration = 0;      // Thời gian user thực sự thấy ads (giây)
  Timer? _viewDurationTimer;
  bool _impressionFired = false;
  bool _clickFired = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
    ));
  }

  // ── Tracking ──────────────────────────────────────

  /// Fire impression tracking khi ads load xong + có nội dung
  void _fireImpressionTracking() {
    if (_impressionFired) return;
    _impressionFired = true;
    debugPrint('SmartLink: Fired impression tracking');
    _loadUrlSilently(_impressionUrl);
  }

  /// Fire click tracking khi user bấm "Xem phim"
  void _fireClickTracking() {
    if (_clickFired) return;
    _clickFired = true;
    debugPrint('SmartLink: Fired click tracking, viewDuration=${_adViewDuration}s');
    _loadUrlSilently(_clickUrl);
  }

  /// Load URL trong background không ảnh hưởng UI
  void _loadUrlSilently(String url) {
    try {
      final request = URLRequest(url: WebUri(url));
      _webController?.loadUrl(urlRequest: request);
    } catch (_) {}
  }

  // ── Countdown — chạy SAU KHI ads load xong ──────

  void _startCountdownAfterAdLoaded() {
    _countdown = _countdownDuration;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      setState(() {
        _countdown--;
        _adViewDuration++;
      });
      if (_countdown <= 0) {
        timer.cancel();
        setState(() => _canProceed = true);
      }
    });
  }

  // ── Ad lifecycle ─────────────────────────────────

  void _onAdLoaded() {
    if (_adLoaded || !mounted) return;
    _adLoaded = true;
    setState(() {
      _isLoading = false;
      _loadFailed = false;
    });
    _fireImpressionTracking();
    _startCountdownAfterAdLoaded();
  }

  void _onAdLoadFailed() {
    if (!mounted) return;
    // Sau khi thử cả 2 URL đều fail → hiển thị nút retry
    if (_triedFallback) {
      setState(() {
        _isLoading = false;
        _loadFailed = true;
      });
    }
  }

  void _retryLoad() {
    setState(() {
      _loadFailed = false;
      _isLoading = true;
      _triedFallback = false;
      _currentUrl = _primaryUrl;
      _adLoaded = false;
    });
    _webController?.loadUrl(urlRequest: URLRequest(url: WebUri(_primaryUrl)));
  }

  // ── Fallback ─────────────────────────────────────

  void _tryFallback() {
    if (_triedFallback) return;
    _triedFallback = true;
    setState(() {
      _currentUrl = _fallbackUrl;
      _isLoading = true;
    });
    _webController?.loadUrl(urlRequest: URLRequest(url: WebUri(_fallbackUrl)));
  }

  // ── Content check ────────────────────────────────

  Future<bool> _checkPageHasContent(InAppWebViewController controller) async {
    try {
      final result = await controller.evaluateJavascript(source: '''
        (function() {
          var imgs = document.querySelectorAll('img');
          var loadedImgs = 0;
          for (var i = 0; i < imgs.length; i++) {
            if (imgs[i].complete && imgs[i].naturalHeight > 0) loadedImgs++;
          }
          var textLen = (document.body.innerText || '').trim().length;
          var bodyH = document.body.scrollHeight || 0;
          var hasIframes = document.querySelectorAll('iframe').length;
          return JSON.stringify({
            loadedImages: loadedImgs,
            totalImages: imgs.length,
            textLength: textLen,
            bodyHeight: bodyH,
            hasIframes: hasIframes
          });
        })()
      ''');
      if (result == null) return false;
      final str = result.toString().replaceAll('"', '');
      final hasImages = RegExp(r'loadedImages:(\d+)').firstMatch(str)?.group(1);
      final bodyH = RegExp(r'bodyHeight:(\d+)').firstMatch(str)?.group(1);
      final textLen = RegExp(r'textLength:(\d+)').firstMatch(str)?.group(1);
      final imgCount = int.tryParse(hasImages ?? '0') ?? 0;
      final height = int.tryParse(bodyH ?? '0') ?? 0;
      final text = int.tryParse(textLen ?? '0') ?? 0;
      return imgCount > 0 || height > 200 || text > 30;
    } catch (_) {
      return false;
    }
  }

  Future<void> _verifyContent() async {
    if (_webController == null || _adLoaded) return;
    for (var i = 0; i < _maxCheckAttempts; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted || _adLoaded) return;
      final hasContent = await _checkPageHasContent(_webController!);
      if (hasContent) {
        _onAdLoaded();
        return;
      }
    }
    // Sau max attempts — ads vẫn chưa có nội dung
    if (!_triedFallback) {
      _tryFallback();
    } else {
      _onAdLoadFailed();
    }
  }

  // ── Finish ───────────────────────────────────────

  void _finish() {
    if (_navigated) return;
    _navigated = true;
    _fireClickTracking();
    _countdownTimer?.cancel();
    _viewDurationTimer?.cancel();
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onComplete();
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _viewDurationTimer?.cancel();
    super.dispose();
  }

  // ── Build ────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_canProceed) {
          _finish();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                color: Colors.black,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 20),
                      onPressed: _canProceed ? _finish : null,
                    ),
                    Expanded(
                      child: Text(
                        _canProceed
                            ? 'Sẵn sàng xem phim'
                            : _adLoaded
                                ? 'Đang tải quảng cáo... (${_countdown}s)'
                                : _loadFailed
                                    ? 'Quảng cáo không tải được'
                                    : 'Đang tải quảng cáo...',
                        style: TextStyle(
                          color: _canProceed ? Colors.white : Colors.white70,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white, size: 22),
                      onPressed: _canProceed ? _finish : null,
                    ),
                  ],
                ),
              ),

              // Loading bar — chỉ hiện khi đang load, KHÔNG chạy countdown
              if (_isLoading && !_loadFailed)
                LinearProgressIndicator(
                  value: null,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation(Color(0xFFF5921E)),
                  minHeight: 3,
                ),

              // Countdown bar — chỉ hiện SAU KHI ads load xong
              if (_adLoaded && !_canProceed)
                Container(
                  height: 28,
                  color: const Color(0xFF1A1A2E),
                  child: Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: _countdown / _countdownDuration,
                          backgroundColor: Colors.white10,
                          valueColor: const AlwaysStoppedAnimation(Color(0xFFF5921E)),
                          minHeight: 28,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          '${_countdown}s',
                          style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),

              // WebView
              Expanded(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(_currentUrl)),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    databaseEnabled: true,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    supportZoom: false,
                    transparentBackground: defaultTargetPlatform == TargetPlatform.iOS,
                    useWideViewPort: true,
                    loadWithOverviewMode: true,
                    mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                    userAgent: 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
                    cacheMode: CacheMode.LOAD_DEFAULT,
                  ),
                  onWebViewCreated: (controller) {
                    _webController = controller;
                  },
                  shouldOverrideUrlLoading: (controller, navigationAction) async {
                    final uri = navigationAction.request.url;
                    if (uri != null) {
                      final scheme = uri.scheme.toLowerCase();
                      if (scheme != 'http' && scheme != 'https' && scheme != 'data') {
                        return NavigationActionPolicy.CANCEL;
                      }
                    }
                    return NavigationActionPolicy.ALLOW;
                  },
                  onProgressChanged: (controller, progress) {
                    if (mounted) {
                      setState(() {
                        _isLoading = progress < 100;
                      });
                    }
                  },
                  onLoadStop: (controller, url) async {
                    _webController = controller;
                    if (!mounted || _adLoaded) return;
                    // Chờ render rồi kiểm tra nội dung
                    await Future.delayed(const Duration(seconds: 2));
                    if (!mounted || _adLoaded) return;
                    final hasContent = await _checkPageHasContent(controller);
                    if (hasContent) {
                      _onAdLoaded();
                    } else {
                      _verifyContent();
                    }
                  },
                  onLoadError: (controller, url, code, message) {
                    debugPrint('SmartLink: Load error $code — $message');
                    if (!mounted || _adLoaded) return;
                    if (!_triedFallback && _currentUrl == _primaryUrl) {
                      Future.delayed(const Duration(seconds: 2), _tryFallback);
                    } else {
                      _onAdLoadFailed();
                    }
                  },
                ),
              ),

              // Error state — ads load fail hoàn toàn
              if (_loadFailed)
                SafeArea(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    color: Colors.black,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.white54, size: 48),
                        const SizedBox(height: 12),
                        const Text(
                          'Không tải được quảng cáo',
                          style: TextStyle(color: Colors.white70, fontSize: 16),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white70,
                                  side: const BorderSide(color: Colors.white30),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                onPressed: _finish,
                                child: const Text('Bỏ qua'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFF5921E),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                onPressed: _retryLoad,
                                child: const Text('Thử lại'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

              // Button "Xem phim"
              if (_canProceed)
                SafeArea(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    color: Colors.black,
                    child: SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF5921E),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _finish,
                        child: const Text(
                          'Xem phim',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
