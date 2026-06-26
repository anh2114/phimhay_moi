import 'package:flutter/material.dart';
import 'package:startapp_sdk/startapp.dart';
import 'package:phimhay_app/services/startapp_ad_service.dart';

class StartAppBannerWidget extends StatefulWidget {
  const StartAppBannerWidget({super.key});

  @override
  State<StartAppBannerWidget> createState() => _StartAppBannerWidgetState();
}

class _StartAppBannerWidgetState extends State<StartAppBannerWidget> {
  StartAppBannerAd? _bannerAd;

  @override
  void initState() {
    super.initState();
    _loadBanner();
  }

  void _loadBanner() {
    StartAppAdService.sdk.loadBannerAd(
      StartAppBannerType.BANNER,
      onAdImpression: () {},
      onAdClicked: () {},
    ).then((ad) {
      if (mounted) setState(() => _bannerAd = ad);
    }).catchError((err) {
      if (mounted) setState(() => _bannerAd = null);
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
}
