import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:phimhay_app/providers/auth_provider.dart';

/// Smart link ad dialog — dùng chung cho mọi screen
/// Admin = skip ad, user thường = hiện ad 5s
class SmartLinkAd {
  static const String smartLinkUrl = 'https://widthwidowzoology.com/ttkzjh3i57?key=dea4ef75a05c9984a67e833b38ac5695';
  static DateTime? _lastShown;
  static const Duration _cooldown = Duration(seconds: 30);

  /// Kiểm tra user có phải admin không
  static bool _isAdmin(BuildContext context) {
    try {
      final user = context.read<AuthProvider>().user;
      return user != null && user['role']?.toString() == 'admin';
    } catch (_) {
      return false;
    }
  }

  /// Hiển thị smart link ad — admin skip, cooldown 30s
  static void show(BuildContext context, {required VoidCallback onComplete}) {
    // ★ FIX: Admin skip ad
    if (_isAdmin(context)) {
      onComplete();
      return;
    }
    // ★ FIX: Cooldown 30s
    if (_lastShown != null && DateTime.now().difference(_lastShown!) < _cooldown) {
      onComplete();
      return;
    }
    _lastShown = DateTime.now();
    int countdown = 5;
    Timer? timer;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            timer?.cancel();
            timer = Timer.periodic(const Duration(seconds: 1), (t) {
              if (Navigator.of(dialogContext).canPop()) {
                setDialogState(() {
                  countdown--;
                  if (countdown <= 0) {
                    t.cancel();
                    Navigator.of(dialogContext).pop();
                    onComplete();
                  }
                });
              } else {
                t.cancel();
              }
            });

            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: EdgeInsets.zero,
              child: Container(
                width: double.infinity,
                height: double.infinity,
                color: Colors.black,
                child: Column(
                  children: [
                    // ★ Header hiện đại — gradient + circular countdown
                    Container(
                      padding: EdgeInsets.only(
                        top: MediaQuery.of(context).padding.top + 4,
                        left: 12, right: 12, bottom: 6,
                      ),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Color(0xFF1A1C21), Color(0xFF2A2D35)],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Left: Ad label + circular progress
                          Row(
                            children: [
                              // Circular countdown
                              SizedBox(
                                width: 28,
                                height: 28,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    CircularProgressIndicator(
                                      value: countdown / 5,
                                      strokeWidth: 2.5,
                                      backgroundColor: Colors.white.withValues(alpha: 0.15),
                                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFF5C84C)),
                                    ),
                                    Text(
                                      '$countdown',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'Quảng cáo',
                                    style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                                  ),
                                  Text(
                                    countdown > 0 ? 'Bỏ qua sau ${countdown}s' : 'Đã hết quảng cáo',
                                    style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 10),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          // Right: Bỏ qua button
                          GestureDetector(
                            onTap: countdown <= 0 ? () {
                              timer?.cancel();
                              Navigator.of(dialogContext).pop();
                              onComplete();
                            } : null,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                              decoration: BoxDecoration(
                                color: countdown <= 0 ? const Color(0xFFF5C84C) : Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: countdown <= 0 ? const Color(0xFFF5C84C) : Colors.white.withValues(alpha: 0.15),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    countdown <= 0 ? Icons.arrow_forward_rounded : Icons.close_rounded,
                                    color: countdown <= 0 ? const Color(0xFF1A1100) : Colors.white38,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    countdown <= 0 ? 'Xem ngay' : 'Bỏ qua',
                                    style: TextStyle(
                                      color: countdown <= 0 ? const Color(0xFF1A1100) : Colors.white54,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // WebView
                    Expanded(
                      child: InAppWebView(
                        initialUrlRequest: URLRequest(url: WebUri(smartLinkUrl)),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          useWideViewPort: true,
                          loadWithOverviewMode: true,
                          supportZoom: false,
                          builtInZoomControls: false,
                          displayZoomControls: false,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      timer?.cancel();
    });
  }
}
