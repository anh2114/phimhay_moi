import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppodealDebugScreen extends StatefulWidget {
  const AppodealDebugScreen({super.key});

  @override
  State<AppodealDebugScreen> createState() => _AppodealDebugScreenState();
}

class _AppodealDebugScreenState extends State<AppodealDebugScreen> {
  static const MethodChannel _channel = MethodChannel('com.xiaofilm/appodeal');
  final List<String> _logs = [];
  Map<String, dynamic> _debugInfo = {};
  bool _loading = false;

  void _log(String msg) {
    final ts = DateTime.now().toString().substring(11, 19);
    setState(() => _logs.add('[$ts] $msg'));
    print('[AppodealDebug] $msg');
  }

  Future<void> _getDebugInfo() async {
    _log('Fetching debug info...');
    try {
      final result = await _channel.invokeMethod('getDebugInfo');
      setState(() => _debugInfo = Map<String, dynamic>.from(result));
      _log('Debug info received ✓');
    } catch (e) {
      _log('ERROR getting debug info: $e');
    }
  }

  Future<void> _initSdk() async {
    _log('Initializing SDK...');
    try {
      final result = await _channel.invokeMethod('initialize', {
        'appKey': '3d38b6d1147aafee7f29a80bd9d3c675598ccd6d705c8d51',
      });
      _log('Initialize result: $result');
      await _getDebugInfo();
    } catch (e) {
      _log('ERROR initializing: $e');
    }
  }

  Future<void> _loadAndShow(String type) async {
    _log('--- $type ---');
    _log('Loading $type...');
    try {
      await _channel.invokeMethod('load$type');
      _log('Load $type called ✓');
    } catch (e) {
      _log('ERROR loading $type: $e');
    }

    await Future.delayed(const Duration(seconds: 2));

    _log('Getting debug info before show...');
    await _getDebugInfo();

    _log('Showing $type...');
    try {
      final result = await _channel.invokeMethod('show$type');
      _log('Show $type result: $result');
    } catch (e) {
      _log('ERROR showing $type: $e');
    }

    await Future.delayed(const Duration(seconds: 1));
    await _getDebugInfo();
  }

  Future<void> _showBanner() async {
    _log('--- Banner ---');
    _log('Loading banner...');
    try {
      await _channel.invokeMethod('loadBanner');
      _log('Load banner called ✓');
    } catch (e) {
      _log('ERROR loading banner: $e');
    }

    await Future.delayed(const Duration(seconds: 2));
    await _getDebugInfo();

    _log('Showing banner...');
    try {
      final result = await _channel.invokeMethod('showBanner');
      _log('Show banner result: $result');
    } catch (e) {
      _log('ERROR showing banner: $e');
    }

    await Future.delayed(const Duration(seconds: 1));
    await _getDebugInfo();
  }

  Future<void> _hideBanner() async {
    try {
      await _channel.invokeMethod('hideBanner');
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
                      onPressed: () => _loadAndShow('Interstitial'),
                      child: const Text('Interstitial'),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: ElevatedButton(
                      onPressed: _showBanner,
                      child: const Text('Banner'),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: ElevatedButton(
                      onPressed: () => _loadAndShow('Rewarded'),
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
                  Text('Plugin init: ${_debugInfo['pluginIsInitialized'] ?? '?'} · '
                      'VC: ${_debugInfo['viewController'] ?? '?'}',
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
                  else if (line.contains('✓') || line.contains('result: true')) color = Colors.green;
                  else if (line.contains('result: false')) color = Colors.orange;
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
    final init = _debugInfo['isInitialized_$prefix'] as bool?;
    final canShow = _debugInfo['canShow_$prefix'] as bool?;
    final autocache = _debugInfo['autocache_$prefix'] as bool?;
    final ecpm = _debugInfo['predictedEcpm_$prefix'] as double?;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 90, child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600))),
          Icon(_boolIcon(init), color: _boolColor(init), size: 14),
          Text(' init ', style: TextStyle(color: Colors.white54, fontSize: 10)),
          Icon(_boolIcon(canShow), color: _boolColor(canShow), size: 14),
          Text(' show ', style: TextStyle(color: Colors.white54, fontSize: 10)),
          Icon(_boolIcon(autocache), color: _boolColor(autocache), size: 14),
          Text(' cache ', style: TextStyle(color: Colors.white54, fontSize: 10)),
          Text('eCPM: \$${ecpm?.toStringAsFixed(2) ?? '0.00'}', style: TextStyle(color: Colors.white54, fontSize: 10)),
        ],
      ),
    );
  }
}
