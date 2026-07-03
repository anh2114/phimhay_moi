import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/smartlink_service.dart';

class SmartlinkInterstitialScreen extends StatefulWidget {
  final String adUrl;
  final VoidCallback onComplete;

  const SmartlinkInterstitialScreen({
    super.key,
    required this.adUrl,
    required this.onComplete,
  });

  @override
  State<SmartlinkInterstitialScreen> createState() => _SmartlinkInterstitialScreenState();
}

class _SmartlinkInterstitialScreenState extends State<SmartlinkInterstitialScreen> {
  InAppWebViewController? _webController;

  // States
  bool _isLoading = true;
  bool _adLoaded = false;
  bool _canProceed = false;
  bool _canSkip = false;
  bool _navigated = false;
  bool _loadFailed = false;
  bool _loadErrorLogged = false;

  // Countdown
  int _countdown = 0;
  static const int _countdownDuration = 7;
  static const int _skipDelay = 3;
  Timer? _countdownTimer;

  // Content check
  static const int _maxCheckAttempts = 5;
  int _adViewDuration = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
    ));
  }

  // ── Countdown ────────────────────────────────────

  void _startCountdown() {
    _countdown = _countdownDuration;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      setState(() {
        _countdown--;
        _adViewDuration++;
        if (_adViewDuration >= _skipDelay && !_canSkip) {
          _canSkip = true;
        }
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
    debugPrint('SmartLink: Ad loaded: ${widget.adUrl}');
    _startCountdown();
  }

  void _onAdLoadFailed() {
    if (!mounted || _loadFailed) return;
    // Xóa link chết khỏi alive list
    SmartlinkService.removeDeadLink(widget.adUrl);
    setState(() {
      _isLoading = false;
      _loadFailed = true;
    });
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
    // Hết attempts mà chưa có content → link chết
    _onAdLoadFailed();
  }

  // ── Finish ───────────────────────────────────────

  void _finish() {
    if (_navigated) return;
    _navigated = true;
    debugPrint('SmartLink: Finished, viewDuration=${_adViewDuration}s');
    SmartlinkService.markAdShown();
    _countdownTimer?.cancel();
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onComplete();
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  // ── Build ────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_canProceed || _canSkip) _finish();
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
                      onPressed: (_canProceed || _canSkip) ? _finish : null,
                    ),
                    Expanded(
                      child: Text(
                        _canProceed
                            ? 'Sẵn sàng xem phim'
                            : _adLoaded
                                ? 'Quảng cáo... (${_countdown}s)'
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
                    if (_canSkip && !_canProceed)
                      GestureDetector(
                        onTap: _finish,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                          ),
                          child: const Text('Bỏ qua', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    if (!_canSkip || _canProceed)
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 22),
                        onPressed: (_canProceed || _canSkip) ? _finish : null,
                      ),
                  ],
                ),
              ),

              // Loading bar
              if (_isLoading && !_loadFailed)
                const LinearProgressIndicator(
                  value: null,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation(Color(0xFFF5921E)),
                  minHeight: 3,
                ),

              // Countdown bar
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
                          _canSkip ? 'Bỏ qua sau ${_countdown}s' : '${_countdown}s',
                          style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),

              // WebView
              Expanded(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(widget.adUrl)),
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
                      setState(() { _isLoading = progress < 100; });
                    }
                  },
                  onLoadStop: (controller, url) async {
                    _webController = controller;
                    if (!mounted || _adLoaded) return;
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
                    if (!_loadErrorLogged) {
                      debugPrint('SmartLink: Load error $code — $message');
                      _loadErrorLogged = true;
                    }
                    if (!mounted || _adLoaded) return;
                    _onAdLoadFailed();
                  },
                ),
              ),

              // Error state
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
                        const Text('Không tải được quảng cáo', style: TextStyle(color: Colors.white70, fontSize: 16)),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFF5921E),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: _finish,
                            child: const Text('Bỏ qua & Xem phim', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                          ),
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
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _finish,
                        child: const Text('Xem phim', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
