import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:startapp_sdk/startapp.dart';
import 'package:phimhay_app/services/startapp_ad_service.dart';

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
  }

  Future<void> _getDebugInfo() async {
    _log('Fetching debug info...');
    try {
      final info = await StartAppAdService.getDebugInfo();
      setState(() => _debugInfo = info);
      _log('Platform: ${info['platform']} | App ID: ${info['appId']}');
      _log('Interstitial: ready=${info['interstitialReady']} loading=${info['interstitialLoading']}');
      _log('Rewarded: ready=${info['rewardedReady']} loading=${info['rewardedLoading']}');
      _log('Native Ads: ${info['nativeAdsCount']}');
    } catch (e) {
      _log('ERROR getting debug info: $e');
    }
  }

  Future<void> _initSdk() async {
    _log('=== Initializing StartApp SDK ===');
    try {
      StartAppAdService.init();
      _log('SDK init called ✓');
      await Future.delayed(const Duration(seconds: 3));
      await _getDebugInfo();
    } catch (e) {
      _log('ERROR initializing: $e');
    }
  }

  Future<void> _loadInterstitial() async {
    _log('--- Loading Interstitial ---');
    try {
      StartAppAdService.sdk.loadInterstitialAd(
        onAdDisplayed: () {
          _log('Interstitial AD_DISPLAYED');
        },
        onAdNotDisplayed: () {
          _log('Interstitial AD_NOT_DISPLAYED');
        },
        onAdHidden: () {
          _log('Interstitial AD_HIDDEN');
        },
        onAdClicked: () {
          _log('Interstitial AD_CLICKED');
        },
      ).then((ad) {
        _log('Interstitial loaded ✓');
        _getDebugInfo();
      }).catchError((error, stackTrace) {
        _log('ERROR loading interstitial: $error');
        return null;
      });
    } catch (e) {
      _log('EXCEPTION: $e');
    }
  }

  Future<void> _showInterstitial() async {
    _log('--- Showing Interstitial ---');
    try {
      StartAppAdService.showInterstitialIfAllowed(
        context,
        onDone: () {
          _log('Interstitial flow completed');
          _getDebugInfo();
        },
      );
    } catch (e) {
      _log('EXCEPTION: $e');
    }
  }

  Future<void> _loadRewardedVideo() async {
    _log('--- Loading Rewarded Video ---');
    try {
      StartAppAdService.sdk.loadRewardedVideoAd(
        onAdNotDisplayed: () {
          _log('Rewarded AD_NOT_DISPLAYED');
        },
        onAdHidden: () {
          _log('Rewarded AD_HIDDEN');
        },
        onVideoCompleted: () {
          _log('Rewarded VIDEO_COMPLETED - reward earned!');
        },
      ).then((ad) {
        _log('Rewarded video loaded ✓');
        _getDebugInfo();
      }).catchError((error, stackTrace) {
        _log('ERROR loading rewarded: $error');
        return null;
      });
    } catch (e) {
      _log('EXCEPTION: $e');
    }
  }

  Future<void> _showRewardedVideo() async {
    _log('--- Showing Rewarded Video ---');
    try {
      StartAppAdService.showRewardedBeforeAction(
        context,
        onReward: () {
          _log('Reward earned!');
        },
        onDone: () {
          _log('Rewarded flow completed');
          _getDebugInfo();
        },
      );
    } catch (e) {
      _log('EXCEPTION: $e');
    }
  }

  Future<void> _loadBanner() async {
    _log('--- Loading Banner ---');
    try {
      StartAppAdService.sdk.loadBannerAd(StartAppBannerType.BANNER).then((bannerAd) {
        _log('Banner loaded ✓');
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Banner Ad Test'),
              content: SizedBox(
                height: 100,
                child: StartAppBanner(bannerAd),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'),
                ),
              ],
            ),
          );
        }
      }).catchError((error, stackTrace) {
        _log('ERROR loading banner: $error');
        return null;
      });
    } catch (e) {
      _log('EXCEPTION: $e');
    }
  }

  Future<void> _toggleTestMode(bool enable) async {
    _log('Setting test mode: $enable');
    try {
      await StartAppAdService.sdk.setTestAdsEnabled(enable);
      _log('Test mode ${enable ? "ENABLED" : "DISABLED"} ✓');
    } catch (e) {
      _log('ERROR setting test mode: $e');
    }
  }

  Color _boolColor(bool? v) => v == true ? Colors.green : Colors.red;
  IconData _boolIcon(bool? v) => v == true ? Icons.check_circle : Icons.cancel;

  @override
  void initState() {
    super.initState();
    _log('=== StartApp Debug Screen ===');
    _log('iOS App ID: 206259683');
    _getDebugInfo();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('StartApp Debug'),
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
                      onPressed: _loadInterstitial,
                      child: const Text('Load Interstitial'),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: ElevatedButton(
                      onPressed: _showInterstitial,
                      child: const Text('Show Interstitial'),
                    )),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: ElevatedButton(
                      onPressed: _loadRewardedVideo,
                      child: const Text('Load Rewarded'),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: ElevatedButton(
                      onPressed: _showRewardedVideo,
                      child: const Text('Show Rewarded'),
                    )),
                  ],
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: _loadBanner,
                  child: const Text('Show Banner'),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Test Ads:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () => _toggleTestMode(true),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                      child: const Text('ON'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () => _toggleTestMode(false),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                      child: const Text('OFF (Real)'),
                    ),
                  ],
                ),
              ],
            ),
          ),

          if (_debugInfo.isNotEmpty)
            Container(
              width: double.infinity,
              color: Colors.grey.shade900,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Platform: ${_debugInfo['platform']} | App ID: ${_debugInfo['appId']}',
                      style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  const SizedBox(height: 4),
                  _buildInfoRow('Interstitial', _debugInfo['interstitialReady'], _debugInfo['interstitialLoading']),
                  _buildInfoRow('Rewarded Video', _debugInfo['rewardedReady'], _debugInfo['rewardedLoading']),
                  Text('Native Ads: ${_debugInfo['nativeAdsCount']}',
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                ],
              ),
            ),

          Expanded(
            child: Container(
              color: Colors.black,
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: _logs.length,
                itemBuilder: (ctx, i) {
                  final line = _logs[_logs.length - 1 - i];
                  Color color = Colors.white70;
                  if (line.contains('ERROR') || line.contains('EXCEPTION')) color = Colors.redAccent;
                  else if (line.contains('✓')) color = Colors.green;
                  else if (line.contains('FAILED')) color = Colors.orange;
                  return Text(line, style: TextStyle(color: color, fontSize: 11, fontFamily: 'monospace'));
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, bool? ready, bool? loading) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 120, child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600))),
          Icon(_boolIcon(ready), color: _boolColor(ready), size: 14),
          Text(' ${ready == true ? "READY" : "NOT READY"}', style: TextStyle(color: ready == true ? Colors.green : Colors.red, fontSize: 10)),
          if (loading == true)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
    );
  }
}
