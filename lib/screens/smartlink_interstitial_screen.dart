import 'dart:async';
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
  static const String _smartlinkUrl = 'https://omg10.com/4/11224550';

  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  double _loadingProgress = 0;
  bool _canProceed = false;
  String _currentUrl = _smartlinkUrl;

  @override
  void initState() {
    super.initState();
    // Prevent back button
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
    ));
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _onLoadComplete() {
    if (mounted && !_canProceed) {
      setState(() {
        _canProceed = true;
        _isLoading = false;
      });
    }
  }

  void _proceedToMovie() {
    widget.onComplete();
    if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<bool> _onWillPop() async {
    if (_canProceed) return true;

    // Show message
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Đợi quảng cáo loading',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: const Text(
            'Vì sự duy trì của app, admin cần có tiền quảng cáo.\n\n'
            'Nhờ mọi người đợi link quảng cáo loading xong thì sẽ xem phim được nha.\n\n'
            'Admin cảm ơn mọi người.',
            style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF5921E),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Đã hiểu'),
            ),
          ],
        ),
      );
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _canProceed,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _onWillPop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                color: Colors.black,
                child: Row(
                  children: [
                    // Back button - disabled until can proceed
                    IconButton(
                      icon: Icon(
                        Icons.arrow_back_ios,
                        color: _canProceed ? Colors.white : Colors.white24,
                        size: 20,
                      ),
                      onPressed: _canProceed
                          ? () => Navigator.pop(context)
                          : () => _onWillPop(),
                    ),
                    const SizedBox(width: 8),
                    // Title
                    Expanded(
                      child: Text(
                        _canProceed ? 'Sẵn sàng xem phim' : 'Đợi quảng cáo...',
                        style: TextStyle(
                          color: _canProceed ? Colors.white : Colors.white70,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    // Close button - only when can proceed
                    if (_canProceed)
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                  ],
                ),
              ),

              // Loading indicator
              if (_isLoading)
                LinearProgressIndicator(
                  value: _loadingProgress > 0 ? _loadingProgress : null,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation(Color(0xFFF5921E)),
                  minHeight: 3,
                ),

              // WebView
              Expanded(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(_smartlinkUrl)),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    useOnLoadResource: true,
                    supportZoom: false,
                    useWideViewPort: true,
                    loadWithOverviewMode: true,
                    transparentBackground: true,
                  ),
                  onWebViewCreated: (controller) {
                    _webViewController = controller;
                  },
                  onLoadStart: (controller, url) {
                    if (mounted) {
                      setState(() {
                        _currentUrl = url.toString();
                      });
                    }
                  },
                  onProgressChanged: (controller, progress) {
                    if (mounted) {
                      setState(() {
                        _loadingProgress = progress / 100;
                      });

                      // Mark as complete when progress reaches 100%
                      if (progress >= 100) {
                        // Wait a bit more for any redirects
                        Future.delayed(const Duration(seconds: 2), () {
                          _onLoadComplete();
                        });
                      }
                    }
                  },
                  onLoadStop: (controller, url) async {
                    // Wait for page to fully load
                    await Future.delayed(const Duration(seconds: 1));
                    _onLoadComplete();
                  },
                  onLoadError: (controller, url, code, message) {
                    // Even on error, allow proceeding after some time
                    Future.delayed(const Duration(seconds: 3), () {
                      _onLoadComplete();
                    });
                  },
                ),
              ),

              // Bottom button - only when can proceed
              if (_canProceed)
                Container(
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
                        elevation: 0,
                      ),
                      onPressed: _proceedToMovie,
                      child: const Text(
                        'Xem phim',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
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
