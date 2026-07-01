import 'dart:io';
import 'package:flutter/material.dart';
import 'package:startapp_sdk/startapp.dart';
import 'package:phimhay_app/services/startapp_ad_service.dart';

class StartAppBannerWidget extends StatefulWidget {
  final bool showDebug;
  const StartAppBannerWidget({super.key, this.showDebug = false});

  @override
  State<StartAppBannerWidget> createState() => _StartAppBannerWidgetState();
}

class _StartAppBannerWidgetState extends State<StartAppBannerWidget> {
  StartAppBannerAd? _bannerAd;
  String _status = 'idle';
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBanner();
  }

  void _loadBanner() {
    final platform = Platform.isIOS ? 'iOS' : (Platform.isAndroid ? 'Android' : 'Unknown');
    print('[StartAppBanner] Loading on $platform...');
    setState(() { _status = 'loading'; _error = null; });

    StartAppAdService.sdk.loadBannerAd(
      StartAppBannerType.BANNER,
      onAdImpression: () {
        print('[StartAppBanner] Impression on $platform');
      },
      onAdClicked: () {
        print('[StartAppBanner] Clicked on $platform');
      },
    ).then((ad) {
      print('[StartAppBanner] Loaded OK on $platform, height=${ad.height}');
      if (mounted) setState(() { _bannerAd = ad; _status = 'loaded'; });
    }).catchError((err) {
      print('[StartAppBanner] FAILED on $platform: $err');
      if (mounted) setState(() { _bannerAd = null; _status = 'failed'; _error = err.toString(); });
      return null;
    });
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.showDebug) {
      return _buildDebug();
    }
    if (_bannerAd == null) return const SizedBox.shrink();
    final h = _bannerAd!.height ?? 52;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: SizedBox(
        height: h,
        child: Center(child: StartAppBanner(_bannerAd!)),
      ),
    );
  }

  Widget _buildDebug() {
    final platform = Platform.isIOS ? 'iOS' : (Platform.isAndroid ? 'Android' : 'Unknown');
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
        border: Border.all(color: statusColor.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(statusIcon, color: statusColor, size: 16),
            const SizedBox(width: 6),
            Text('StartApp Banner [$platform]',
                style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 4),
          Text('Status: $_status', style: const TextStyle(color: Colors.white70, fontSize: 11)),
          if (_error != null)
            Text('Error: $_error', style: const TextStyle(color: Colors.redAccent, fontSize: 10)),
          if (_bannerAd != null)
            SizedBox(
              height: _bannerAd!.height ?? 52,
              child: StartAppBanner(_bannerAd!),
            ),
        ],
      ),
    );
  }
}
