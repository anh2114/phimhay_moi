import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'services/api_client.dart';
import 'services/activity_service.dart';
import 'config/theme.dart';
import 'providers/home_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/favorite_provider.dart';
import 'providers/watch_history_provider.dart';
import 'providers/reminder_provider.dart';
import 'providers/collection_provider.dart';
import 'screens/home/home_screen.dart';
import 'screens/splash/splash_screen.dart';
import 'services/push_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Tablet cho phep xoay tu do, mobile chi portrait
  final size = WidgetsBinding.instance.window.physicalSize;
  final shortestSide = size.shortestSide / WidgetsBinding.instance.window.devicePixelRatio;
  final isLargeIpad = shortestSide > 750;
  final isTablet = shortestSide >= 600;

  await SystemChrome.setPreferredOrientations(
    isLargeIpad
        ? [
            DeviceOrientation.portraitUp,
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : isTablet
            ? [DeviceOrientation.portraitUp]
            : [DeviceOrientation.portraitUp],
  );

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  await ApiClient.init();

  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('cache_cleared_v2') != true) {
      await DefaultCacheManager().emptyCache();
      await prefs.setBool('cache_cleared_v2', true);
    }
  } catch (_) {}

  await Firebase.initializeApp();
  PushService.init();

  // Initialize liquid glass widgets
  await LiquidGlassWidgets.initialize();

  // Initialize activity tracking
  ActivityService.init();

  runApp(
    LiquidGlassWidgets.wrap(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => HomeProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => FavoriteProvider()),
          ChangeNotifierProvider(create: (_) => WatchHistoryProvider()),
          ChangeNotifierProvider(create: (_) => ReminderProvider()),
          ChangeNotifierProvider(create: (_) => CollectionProvider()),
        ],
        child: const XiaoPhimApp(),
      ),
    ),
  );
}

class XiaoPhimApp extends StatelessWidget {
  const XiaoPhimApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Xiao Phim',
      theme: AppTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      home: SplashScreen(child: const HomeScreen()),
      routes: {
        '/debug/ads': (_) => const Scaffold(body: Center(child: Text('Ad debug removed'))),
      },
    );
  }
}