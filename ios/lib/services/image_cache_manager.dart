import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Custom cache manager — 30 ngày TTL, stale-while-revalidate
class AppImageCacheManager extends CacheManager {
  static const key = 'phimhay_images_v1';
  static final AppImageCacheManager _instance = AppImageCacheManager._();
  factory AppImageCacheManager() => _instance;
  AppImageCacheManager._()
      : super(
          Config(
            key,
            stalePeriod: const Duration(days: 30),
            maxNrOfCacheObjects: 2000,
          ),
        );
}
