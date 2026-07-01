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

  bool _isLoading = true;
  double _loadingProgress = 0;
  bool _canProceed = false;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
    ));
  }

  void _onLoadComplete() {
    if (mounted && !_canProceed) {
      setState(() {
        _canProceed = true;
        _isLoading = false;
      });
    }
  }

  void _finish() {
    if (_navigated) return;
    _navigated = true;
    // Pop first
    Navigator.of(context).pop();
    // Then call onComplete after pop completes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onComplete();
    });
  }

  void _showWarning() {
    if (!mounted) return;
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
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Đã hiểu'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_canProceed) {
          _finish();
        } else {
          _showWarning();
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
                      onPressed: _canProceed ? _finish : _showWarning,
                    ),
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
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white, size: 22),
                      onPressed: _canProceed ? _finish : _showWarning,
                    ),
                  ],
                ),
              ),

              if (_isLoading)
                LinearProgressIndicator(
                  value: _loadingProgress > 0 ? _loadingProgress : null,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation(Color(0xFFF5921E)),
                  minHeight: 3,
                ),

              Expanded(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(_smartlinkUrl)),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    supportZoom: false,
                    transparentBackground: true,
                  ),
                  onProgressChanged: (controller, progress) {
                    if (mounted) {
                      setState(() {
                        _loadingProgress = progress / 100;
                      });
                      if (progress >= 100) {
                        Future.delayed(const Duration(seconds: 2), _onLoadComplete);
                      }
                    }
                  },
                  onLoadStop: (controller, url) async {
                    await Future.delayed(const Duration(seconds: 1));
                    _onLoadComplete();
                  },
                  onLoadError: (controller, url, code, message) {
                    Future.delayed(const Duration(seconds: 3), _onLoadComplete);
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
