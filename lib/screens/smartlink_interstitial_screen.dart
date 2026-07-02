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

  InAppWebViewController? _webController;
  String _currentUrl = _primaryUrl;
  bool _isLoading = true;
  bool _canProceed = false;
  bool _navigated = false;
  bool _triedFallback = false;
  int _countdown = 15;
  Timer? _countdownTimer;
  int _contentCheckAttempts = 0;
  static const int _maxCheckAttempts = 10;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
    ));
    _startCountdown();
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      setState(() => _countdown--);
      if (_countdown <= 0) {
        timer.cancel();
        if (!_canProceed) {
          _tryFallback();
        }
      }
    });
  }

  void _tryFallback() {
    if (_triedFallback) return;
    _triedFallback = true;
    _contentCheckAttempts = 0;
    setState(() {
      _currentUrl = _fallbackUrl;
      _isLoading = true;
    });
    _webController?.loadUrl(urlRequest: URLRequest(url: WebUri(_fallbackUrl)));
  }

  void _markReady() {
    if (mounted && !_canProceed) {
      _countdownTimer?.cancel();
      setState(() {
        _canProceed = true;
        _isLoading = false;
      });
    }
  }

  /// Kiểm tra trang ads có nội dung thực sự không
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

  /// Poll kiểm tra nội dung sau khi page load xong
  Future<void> _verifyContent() async {
    if (_webController == null) return;
    for (var i = 0; i < _maxCheckAttempts; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted || _canProceed) return;
      final hasContent = await _checkPageHasContent(_webController!);
      _contentCheckAttempts++;
      if (hasContent) {
        _markReady();
        return;
      }
    }
    // Sau max attempts — bắt buộc cho proceed
    _markReady();
  }

  void _finish() {
    if (_navigated) return;
    _navigated = true;
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
                            : _isLoading
                                ? 'Đang tải quảng cáo... ($_countdown)s'
                                : 'Đợi xác nhận...',
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

              if (_isLoading)
                LinearProgressIndicator(
                  value: null,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation(Color(0xFFF5921E)),
                  minHeight: 3,
                ),

              // Countdown bar
              if (!_canProceed)
                Container(
                  height: 28,
                  color: const Color(0xFF1A1A2E),
                  child: Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: _countdown / 15,
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
                    if (!mounted || _canProceed) return;
                    // Chờ render rồi kiểm tra nội dung
                    await Future.delayed(const Duration(seconds: 2));
                    if (!mounted || _canProceed) return;
                    final hasContent = await _checkPageHasContent(controller);
                    if (hasContent) {
                      _markReady();
                    } else {
                      // Poll tiếp
                      _verifyContent();
                    }
                  },
                  onLoadError: (controller, url, code, message) {
                    if (!mounted || _canProceed) return;
                    // Lỗi load → thử fallback URL
                    if (!_triedFallback && _currentUrl == _primaryUrl) {
                      Future.delayed(const Duration(seconds: 2), _tryFallback);
                    }
                  },
                ),
              ),

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
