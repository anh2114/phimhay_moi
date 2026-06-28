import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:phimhay_app/services/applovin_ad_service.dart';

class AppLovinBannerWidget extends StatefulWidget {
  final bool showDebug;
  const AppLovinBannerWidget({super.key, this.showDebug = false});

  @override
  State<AppLovinBannerWidget> createState() => _AppLovinBannerWidgetState();
}

class _AppLovinBannerWidgetState extends State<AppLovinBannerWidget> {
  String _status = 'idle';
  String? _error;
  Timer? _retryTimer;
  int _retryCount = 0;
  static const int _maxRetries = 8;

  @override
  void initState() {
    super.initState();
    _loadBanner();
  }

  void _loadBanner() {
    if (!Platform.isIOS) return;
    print('[AppodealBanner] Loading on iOS (attempt ${_retryCount + 1})...');
    setState(() { _status = 'loading'; _error = null; });

    AppLovinAdService.loadBanner();
    
    // Check if banner is ready after delay
    Future.delayed(const Duration(seconds: 3), () async {
      if (!mounted) return;
      final ready = await AppLovinAdService.showBanner();
      if (ready) {
        print('[AppodealBanner] Banner shown successfully on iOS');
        if (mounted) setState(() { _status = 'loaded'; });
      } else {
        _retryCount++;
        if (_retryCount < _maxRetries) {
          print('[AppodealBanner] Not ready, retry ${_retryCount}/$_maxRetries in 5s...');
          _retryTimer = Timer(const Duration(seconds: 5), () {
            if (mounted) _loadBanner();
          });
        } else {
          print('[AppodealBanner] Failed after $_maxRetries retries');
          if (mounted) setState(() { _status = 'failed'; _error = 'Max retries reached'; });
        }
      }
    });
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.showDebug) return _buildDebug();
    if (_status != 'loaded') return const SizedBox.shrink();
    // Appodeal renders banner natively at bottom — this widget is just a spacer
    return const SizedBox(height: 50);
  }

  Widget _buildDebug() {
    Color statusColor;
    IconData statusIcon;
    switch (_status) {
      case 'loaded':
        statusColor = Colors.green;
        statusIcon = Icons.check_circle;
        break;
      case 'loading':
        statusColor = Colors.orange;
        statusIcon = Icons.hourglass_top;
        break;
      case 'failed':
        statusColor = Colors.red;
        statusIcon = Icons.error;
        break;
      default:
        statusColor = Colors.grey;
        statusIcon = Icons.help_outline;
    }

    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: statusColor.withAlpha(128)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(statusIcon, color: statusColor, size: 16),
            const SizedBox(width: 6),
            Text('Appodeal Banner [iOS]',
                style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 4),
          Text('Status: $_status', style: const TextStyle(color: Colors.white70, fontSize: 11)),
          Text('Retries: $_retryCount/$_maxRetries', style: const TextStyle(color: Colors.white54, fontSize: 10)),
          if (_error != null)
            Text('Error: $_error', style: const TextStyle(color: Colors.redAccent, fontSize: 10)),
        ],
      ),
    );
  }
}
