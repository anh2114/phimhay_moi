import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_config.dart';

/// Kết quả kiểm tra update
class UpdateInfo {
  final bool hasUpdate;
  final String latest;
  final String url;
  final String notes;
  final bool force;

  UpdateInfo({
    required this.hasUpdate,
    required this.latest,
    required this.url,
    required this.notes,
    required this.force,
  });

  factory UpdateInfo.noUpdate() => UpdateInfo(
    hasUpdate: false, latest: '', url: '', notes: '', force: false,
  );
}

class UpdateService {
  final Dio _dio = Dio();
  static const _channel = MethodChannel('phimhay/install_apk');

  /// Kiểm tra có bản mới không
  Future<UpdateInfo> checkUpdate() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final platform = Platform.isAndroid ? 'android' : 'ios';
      final res = await _dio.get(
        '${AppConfig.apiUrl}/app_update/app_version.php',
        queryParameters: {
          'platform': platform,
          'current': currentVersion,
        },
      );

      final data = res.data;
      if (data == null || data['error'] != null) {
        return UpdateInfo.noUpdate();
      }

      return UpdateInfo(
        hasUpdate: data['has_update'] == true,
        latest: data['latest'] ?? '',
        url: data['url'] ?? '',
        notes: data['notes'] ?? '',
        force: data['force'] == true,
      );
    } catch (e) {
      return UpdateInfo.noUpdate();
    }
  }

  /// Download APK và mở installer (Android)
  Future<void> downloadAndInstall(String url, {Function(double)? onProgress}) async {
    try {
      final dir = await getTemporaryDirectory();
      final version = url.split('/').last.replaceAll('.apk', '').replaceAll('.ipa', '');
      final filePath = '${dir.path}/$version.apk';

      // Xóa file APK cũ trước khi tải mới
      try {
        final oldFiles = dir.listSync().where((f) => f.path.endsWith('.apk'));
        for (var f in oldFiles) {
          await f.delete();
        }
      } catch (_) {}
      // Download APK
      await _dio.download(
        url,
        filePath,
        onReceiveProgress: (received, total) {
          if (total > 0 && onProgress != null) {
            onProgress(received / total);
          }
        },
      );

      // Kiểm tra file đã tồn tại chưa
      final file = File(filePath);
      final exists = await file.exists();
      final size = exists ? await file.length() : 0;
      // Mở APK để cài đặt
      if (Platform.isAndroid) {
        final installResult = await _installApk(filePath);
        if (installResult == 'need_permission') {
          throw Exception('Cần cấp quyền cài đặt ứng dụng. Vui lòng bật "Cho phép cài đặt từ nguồn không xác định" trong Cài đặt.');
        }
      } else {
        // iOS: dùng itms-services:// protocol cho OTA install
        final manifestUrl = 'https://junyphoret.online/downloads/manifest.php';
        final itmsUrl = 'itms-services://?action=download-manifest&url=${Uri.encodeComponent(manifestUrl)}';
        final uri = Uri.parse(itmsUrl);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } else {
          // Fallback: mở manifest trực tiếp
          final manifestUri = Uri.parse(manifestUrl);
          if (await canLaunchUrl(manifestUri)) {
            await launchUrl(manifestUri, mode: LaunchMode.externalApplication);
          }
        }
      }
    } catch (e, stackTrace) {
      rethrow;
    }
  }

  /// Gọi Android Intent để cài đặt APK
  /// Trả về: 'ok' nếu thành công, 'need_permission' nếu cần user cấp quyền, 'error' nếu lỗi
  Future<String> _installApk(String filePath) async {
    try {
      final result = await _channel.invokeMethod('installApk', {'path': filePath});
      return 'ok';
    } on PlatformException catch (e) {
      if (e.code == 'NEED_PERMISSION') {
        return 'need_permission';
      }
      return 'error';
    } catch (e) {
      return 'error';
    }
  }
}
