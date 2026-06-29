import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:stack_appodeal_flutter/appodeal.dart';

class AppodealDebugScreen extends StatefulWidget {
  const AppodealDebugScreen({super.key});

  @override
  State<AppodealDebugScreen> createState() => _AppodealDebugScreenState();
}

class _AppodealDebugScreenState extends State<AppodealDebugScreen> {
  final List<String> _logs = [];
  Map<String, dynamic> _debugInfo = {};

  void _log(String msg) {
    final ts = DateTime.now().toString().substring(11, 19);
    setState(() => _logs.add('[$ts] $msg'));
    print('[AppodealDebug] $msg');
  }

  Future<void> _getDebugInfo() async {
    _log('Fetching debug info...');
    try {
      final canShowInterstitial = await Appodeal.canShow(AppodealAdType.Interstitial);
      final canShowBanner = await Appodeal.canShow(AppodealAdType.Banner);
      final canShowRewarded = await Appodeal.canShow(AppodealAdType.RewardedVideo);

      final isLoadedInterstitial = await Appodeal.isLoaded(AppodealAdType.Interstitial);
      final isLoadedBanner = await Appodeal.isLoaded(AppodealAdType.Banner);
      final isLoadedRewarded = await Appodeal.isLoaded(AppodealAdType.RewardedVideo);

      setState(() => _debugInfo = {
        'canShow_interstitial': canShowInterstitial,
        'canShow_banner': canShowBanner,
        'canShow_rewardedVideo': canShowRewarded,
        'isLoaded_interstitial': isLoadedInterstitial,
        'isLoaded_banner': isLoadedBanner,
        'isLoaded_rewardedVideo': isLoadedRewarded,
      });
      _log('Debug info received ✓');
    } catch (e) {
      _log('ERROR getting debug info: $e');
    }
  }

  Future<void> _initSdk() async {
    _log('Initializing SDK...');
    try {
      await Appodeal.initialize(
        appKey: '3d38b6d1147aafee7f29a80bd9d3c675598ccd6d705c8d51',
        adTypes: [
          AppodealAdType.Interstitial,
          AppodealAdType.RewardedVideo,
          AppodealAdType.Banner,
        ],
        onInitializationFinished: (errors) {
          if (errors != null && errors.isNotEmpty) {
            _log('Init errors: $errors');
          } else {
            _log('SDK initialized ✓');
          }
        },
      );
      await _getDebugInfo();
    } catch (e) {
      _log('ERROR initializing: $e');
    }
  }

  Future<void> _cacheAndShow(AppodealAdType type, String name) async {
    _log('--- $name ---');
    _log('Caching $name...');
    try {
      Appodeal.cache(type);
      _log('Cache $name called ✓');
    } catch (e) {
      _log('ERROR caching $name: $e');
    }

    await Future.delayed(const Duration(seconds: 2));
    await _getDebugInfo();

    _log('Showing $name...');
    try {
      Appodeal.show(type);
      _log('Show $name called ✓');
    } catch (e) {
      _log('ERROR showing $name: $e');
    }

    await Future.delayed(const Duration(seconds: 1));
    await _getDebugInfo();
  }

  Future<void> _showBanner() async {
    _log('--- Banner ---');
    _log('Caching banner...');
    try {
      Appodeal.cache(AppodealAdType.Banner);
      _log('Cache banner called ✓');
    } catch (e) {
      _log('ERROR caching banner: $e');
    }

    await Future.delayed(const Duration(seconds: 2));
    await _getDebugInfo();

    _log('Showing banner...');
    try {
      Appodeal.show(AppodealAdType.BannerBottom);
      _log('Show banner called ✓');
    } catch (e) {
      _log('ERROR showing banner: $e');
    }

    await Future.delayed(const Duration(seconds: 1));
    await _getDebugInfo();
  }

  Future<void> _hideBanner() async {
    try {
      Appodeal.hide(AppodealAdType.BannerBottom);
      _log('Banner hidden ✓');
    } catch (e) {
      _log('ERROR hiding banner: $e');
    }
  }

  Color _boolColor(bool? v) => v == true ? Colors.green : Colors.red;
  IconData _boolIcon(bool? v) => v == true ? Icons.check_circle : Icons.cancel;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Appodeal Debug'),
        backgroundColor: Colors.black87,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _getDebugInfo,
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: Column(
        children: [
          // Action buttons
          Container(
            color: Colors.grey.shade900,
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: ElevatedButton(
                      onPressed: _initSdk,
                      child: const Text('Init SDK'),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: ElevatedButton(
                      onPressed: _getDebugInfo,
                      child: const Text('Get Info'),
                    )),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: ElevatedButton(
                      onPressed: () => _cacheAndShow(AppodealAdType.Interstitial, 'Interstitial'),
                      child: const Text('Interstitial'),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: ElevatedButton(
                      onPressed: _showBanner,
                      child: const Text('Banner'),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: ElevatedButton(
                      onPressed: () => _cacheAndShow(AppodealAdType.RewardedVideo, 'Rewarded'),
                      child: const Text('Rewarded'),
                    )),
                  ],
                ),
                const SizedBox(height: 4),
                ElevatedButton(
                  onPressed: _hideBanner,
                  child: const Text('Hide Banner'),
                ),
              ],
            ),
          ),

          // Debug info panel
          if (_debugInfo.isNotEmpty)
            Container(
              width: double.infinity,
              color: Colors.grey.shade900,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Platform: ${Platform.isIOS ? "iOS" : "Android"}',
                      style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  const SizedBox(height: 6),
                  _buildInfoRow('Interstitial', 'interstitial'),
                  _buildInfoRow('Banner', 'banner'),
                  _buildInfoRow('Rewarded', 'rewardedVideo'),
                ],
              ),
            ),

          // Logs
          Expanded(
            child: Container(
              color: Colors.black,
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: _logs.length,
                itemBuilder: (ctx, i) {
                  final line = _logs[_logs.length - 1 - i];
                  Color color = Colors.white70;
                  if (line.contains('ERROR')) color = Colors.redAccent;
                  else if (line.contains('✓') || line.contains('true')) color = Colors.green;
                  else if (line.contains('false')) color = Colors.orange;
                  return Text(line, style: TextStyle(color: color, fontSize: 11, fontFamily: 'monospace'));
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String prefix) {
    final canShow = _debugInfo['canShow_$prefix'] as bool?;
    final isLoaded = _debugInfo['isLoaded_$prefix'] as bool?;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 90, child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600))),
          Icon(_boolIcon(canShow), color: _boolColor(canShow), size: 14),
          Text(' canShow ', style: TextStyle(color: Colors.white54, fontSize: 10)),
          Icon(_boolIcon(isLoaded), color: _boolColor(isLoaded), size: 14),
          Text(' isLoaded', style: TextStyle(color: Colors.white54, fontSize: 10)),
        ],
      ),
    );
  }
}
