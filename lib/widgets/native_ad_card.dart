import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:startapp_sdk/startapp.dart';
import 'package:phimhay_app/config/theme.dart';

class NativeAdCard extends StatelessWidget {
  final StartAppNativeAd nativeAd;
  const NativeAdCard({super.key, required this.nativeAd});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      child: StartAppNative(
        nativeAd,
        (context, setState, ad) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: ad.imageUrl != null
                  ? CachedNetworkImage(
                      imageUrl: ad.imageUrl!,
                      width: 132,
                      height: 198,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        width: 132,
                        height: 198,
                        color: Colors.grey.shade900,
                        child: const Icon(Icons.ad_units, color: Colors.amber, size: 40),
                      ),
                    )
                  : Container(
                      width: 132,
                      height: 198,
                      color: Colors.grey.shade900,
                      child: const Icon(Icons.ad_units, color: Colors.amber, size: 40),
                    ),
            ),
            const SizedBox(height: 6),
            if (ad.title != null)
              Text(
                ad.title!,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (ad.callToAction != null)
              Container(
                margin: const EdgeInsets.only(top: 3),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.shade700,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  ad.callToAction!,
                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
                ),
              ),
          ],
        ),
        height: 260,
      ),
    );
  }
}
