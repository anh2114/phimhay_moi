import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:phimhay_app/services/api_client.dart';

class PushService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  static final StreamController<RemoteMessage> _messageController =
      StreamController<RemoteMessage>.broadcast();

  static Stream<RemoteMessage> get onMessage => _messageController.stream;

  static Future<void> init() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    // Fix hang on iOS: Wrap token getting in try-catch and wait for APNS on iOS
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        final apnsToken = await _messaging.getAPNSToken();
        if (apnsToken == null) {
        }
      }

      final token = await _messaging.getToken();
    } catch (e) {
    }

    _messaging.onTokenRefresh.listen((newToken) {
      _sendTokenToServer(newToken);
    });

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      _messageController.add(message);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _messageController.add(message);
    });

    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      _messageController.add(initialMessage);
    }
  }

  /// Gửi FCM token lên server — thử retry 5 lần nếu chưa có token
  /// Trả về chuỗi kết quả (success hoặc chi tiết lỗi) để hiển thị lên UI
  static Future<String> sendTokenToServerAfterLogin() async {
    String? token;
    String getTokError = '';
    for (int i = 0; i < 5; i++) {
      try {
        token = await _messaging.getToken();
      } catch (e) {
        getTokError = e.toString();
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
      if (token != null && token.isNotEmpty) {
        break;
      }
      await Future.delayed(const Duration(seconds: 1));
    }

    if (token == null || token.isEmpty) {
      return 'Không lấy được FCM token. Lỗi: $getTokError';
    }

    String sendError = '';
    for (int i = 0; i < 3; i++) {
      try {
        final res = await ApiClient.post(
          '/PushSubscription.php',
          data: {
            'action': 'save_fcm',
            'fcm_token': token,
          },
        );

        dynamic responseData = res.data;
        if (responseData is String) {
          try {
            responseData = jsonDecode(responseData);
          } catch (_) {}
        }

        if (responseData is Map) {
          if (responseData['success'] == true) {
            return 'SUCCESS';
          } else {
            sendError = responseData['error'] ?? 'Server trả về success=false';
          }
        } else {
          sendError = 'Response không phải JSON Map: $responseData';
        }
      } catch (e) {
        sendError = e.toString();
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    return 'Lỗi gửi token: $sendError';
  }

  static Future<bool> _sendTokenToServer(String token) async {
    try {
      final res = await ApiClient.post(
        '/PushSubscription.php',
        data: {
          'action': 'save_fcm',
          'fcm_token': token,
        },
      );

      dynamic responseData = res.data;
      if (responseData is String) {
        try {
          responseData = jsonDecode(responseData);
        } catch (_) {}
      }

      if (responseData is Map) {
        return responseData['success'] == true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  static Future<void> subscribeToMovie(String movieSlug) async {
    try {
      final topic = 'movie_${movieSlug.replaceAll(RegExp(r'[^a-z0-9_]'), '_')}';
      await _messaging.subscribeToTopic(topic);
    } catch (e) {
    }
  }

  static Future<void> unsubscribeFromMovie(String movieSlug) async {
    try {
      final topic = 'movie_${movieSlug.replaceAll(RegExp(r'[^a-z0-9_]'), '_')}';
      await _messaging.unsubscribeFromTopic(topic);
    } catch (e) {
    }
  }

  static Future<String?> getToken() async {
    try {
      return await _messaging.getToken();
    } catch (e) {
      return null;
    }
  }
}