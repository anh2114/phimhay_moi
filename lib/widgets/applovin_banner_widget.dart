import 'dart:io';
import 'package:flutter/material.dart';
import 'package:applovin_max/applovin_max.dart';
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

  @override
  void initState() {
    super.initState();
    _loadBanner();
  }

  void _loadBanner() {
    final platform = Platform.isIOS ? 'iOS' : 'Android';
    print('[AppLovinBanner] Loading on $platform...');
    setState(() { _status = 'loading'; _error = null; });

    AppLovinMAX.setBannerListener(BannerListener(
      onBannerLoaded: (ad) {
        print('[AppLovinBanner] Loaded on $platform, size=${ad.adSize}');
        if (mounted) setState(() { _status = 'loaded'; });
      },
      onBannerLoadFailed: (adUnitId, error) {
        print('[AppLovinBanner] FAILED on $platform: ${error.message}');
        if (mounted) setState(() { _status = 'failed'; _error = error.message; });
        // Retry after 15s
        Future.delayed(const Duration(seconds: 15), () {
          if (mounted) _loadBanner();
        });
      },
      onBannerClicked: (ad) {
        print('[AppLovinBanner] Clicked on $platform');
      },
      onBannerDisplayed: (ad) {
        print('[AppLovinBanner] Displayed on $platform');
      },
      onBannerAdRevenuePaid: (ad, revenue) {
        print('[AppLovinBanner] Revenue: \$$revenue');
      },
    ));

    AppLovinMAX.loadBanner(AppLovinAdService.bannerAdUnitId, AdViewPosition.centered);
  }

  @override
  void dispose() {
    AppLovinMAX.destroyBanner(AppLovinAdService.bannerAdUnitId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.showDebug) return _buildDebug();
    if (_status != 'loaded') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: SizedBox(
        height: 50,
        child: MaxAdView(
          adUnitId: AppLovinAdService.bannerAdUnitId,
          adFormat: AdFormat.banner,
        ),
      ),
    );
  }

  Widget _buildDebug() {
    final platform = Platform.isIOS ? 'iOS' : 'Android';
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
            Text('AppLovin Banner [$platform]',
                style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 4),
          Text('Status: $_status', style: const TextStyle(color: Colors.white70, fontSize: 11)),
          if (_error != null)
            Text('Error: $_error', style: const TextStyle(color: Colors.redAccent, fontSize: 10)),
          if (_status == 'loaded')
            SizedBox(
              height: 50,
              child: MaxAdView(
                adUnitId: AppLovinAdService.bannerAdUnitId,
                adFormat: AdFormat.banner,
              ),
            ),
        ],
      ),
    );
  }
}
