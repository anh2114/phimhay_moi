/// ═══════════════════════════════════════════════════════════════════
/// M3U8 AD PARSER — Usage Example in WatchScreen
/// ═══════════════════════════════════════════════════════════════════
///
/// Copy these snippets into watch_screen.dart to integrate ad detection.
/// This is NOT production code — it shows the integration pattern.
///
library;

// ─────────────────────────────────────────────────────────────────
// STEP 1: Add fields to _WatchScreenState
// ─────────────────────────────────────────────────────────────────

/*
  // M3U8 Ad Parser
  final M3u8AdParser _adParser = M3u8AdParser();
  M3u8ParseResult? _m3u8Result;
  bool _adMode = false;           // Currently showing ad overlay?
  int _adRemainingSec = 0;        // Countdown for ad
  Timer? _adCountdownTimer;
*/

// ─────────────────────────────────────────────────────────────────
// STEP 2: Parse m3u8 when player loads (call from _initHlsPlayer)
// ─────────────────────────────────────────────────────────────────

/*
  /// Parse m3u8 for ad detection — call after opening media
  Future<void> _parseM3u8ForAds(String m3u8Url) async {
    try {
      _m3u8Result = await _adParser.parse(m3u8Url);
      if (_m3u8Result!.hasAds) {
        for (final zone in _m3u8Result!.adZones) {
        }
      }
    } catch (e) {
    }
  }
*/

// ─────────────────────────────────────────────────────────────────
// STEP 3: Replace _checkAdZone with parsed version
// ─────────────────────────────────────────────────────────────────

/*
  /// Check if position hits an ad zone from m3u8 parsing
  void _checkAdZoneParsed(int positionSec) {
    if (_m3u8Result == null || !_m3u8Result!.hasAds || _adMode) return;

    final adZone = _m3u8Result!.adZoneAt(positionSec.toDouble());
    if (adZone == null) return;
    // Option A: Skip ad entirely (jump to end)
    _hlsPlayer?.seek(Duration(seconds: adZone.endTime.toInt()));

    // Option B: Show ad simulation overlay (see STEP 4)
    // _showAdOverlay(adZone);
  }
*/

// ─────────────────────────────────────────────────────────────────
// STEP 4: Ad simulation overlay (Option B)
// ─────────────────────────────────────────────────────────────────

/*
  void _showAdOverlay(AdZone adZone) {
    _adMode = true;
    _adRemainingSec = adZone.duration.toInt();

    // Pause movie
    _hlsPlayer?.pause();

    // Start countdown
    _adCountdownTimer?.cancel();
    _adCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      setState(() {
        _adRemainingSec--;
        if (_adRemainingSec <= 0) {
          _dismissAdOverlay(adZone);
          timer.cancel();
        }
      });
    });

    setState(() {});
  }

  void _dismissAdOverlay(AdZone adZone) {
    _adMode = false;
    _adCountdownTimer?.cancel();

    // Seek back to where movie was before ad
    _hlsPlayer?.seek(Duration(seconds: adZone.endTime.toInt()));
    _hlsPlayer?.play();

    setState(() {});
  }
*/

// ─────────────────────────────────────────────────────────────────
// STEP 5: UI overlay widget (add inside _buildPlayer Stack)
// ─────────────────────────────────────────────────────────────────

/*
  // Inside _buildPlayer() → Stack children:
  if (_adMode)
    Positioned.fill(
      child: Container(
        color: Colors.black87,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.ad_units, color: Colors.amber, size: 48),
              const SizedBox(height: 12),
              const Text(
                'Quảng cáo',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 8),
              Text(
                '$_adRemainingSec giây',
                style: const TextStyle(
                  color: Colors.amber,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              // Progress bar
              SizedBox(
                width: 200,
                child: LinearProgressIndicator(
                  value: _adRemainingSec / /* adZone.duration */ 30,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation(Colors.amber),
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => _dismissAdOverlay(/* adZone */ ...),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white38),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('Bỏ qua ▸', style: TextStyle(color: Colors.white70, fontSize: 13)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
*/

// ─────────────────────────────────────────────────────────────────
// STEP 6: Wire into position listener
// ─────────────────────────────────────────────────────────────────

/*
  // Inside _positionSub listener:
  _positionSub = _hlsPlayer!.stream.position.distinct().listen((pos) {
    final sec = pos.inSeconds;

    // Check ad zone from m3u8 parsing
    _checkAdZoneParsed(sec);

    // ... rest of existing position listener code
  });
*/

// ─────────────────────────────────────────────────────────────────
// STEP 7: Clean up on dispose
// ─────────────────────────────────────────────────────────────────

/*
  // Inside dispose():
  _adCountdownTimer?.cancel();
*/
