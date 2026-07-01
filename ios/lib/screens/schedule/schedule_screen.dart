import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:phimhay_app/services/api_client.dart';
import '../../config/app_config.dart';
import '../../config/theme.dart';
import '../movie_detail/movie_detail_screen.dart';

class ScheduleScreen extends StatefulWidget {
  final bool isTab;
  const ScheduleScreen({super.key, this.isTab = false});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> with AutomaticKeepAliveClientMixin {
  final Dio _dio = ApiClient.dio;
  List<Map<String, dynamic>> _schedules = [];
  bool _isLoading = false;
  String? _error;

  // Category filter
  String _currentFilter = 'all';

  // ★ B: Multi-day support
  int _selectedDay = 0; // 0=today, 1=tmrw, ...6
  List<Map<String, dynamic>> _dayLabels = [];

  // Cache schedules per day
  final Map<int, List<Map<String, dynamic>>> _dayCache = {};

  @override
  bool get wantKeepAlive => widget.isTab;

  @override
  void initState() {
    super.initState();
    _loadSchedule(0);
  }

  Future<void> _loadSchedule(int day) async {
    if (_dayCache.containsKey(day) && day == _selectedDay) {
      setState(() {
        _schedules = _dayCache[day]!;
        _isLoading = false;
        _currentFilter = 'all';
      });
      return;
    }
    setState(() { _isLoading = true; _error = null; _currentFilter = 'all'; });
    try {
      final res = await _dio.get(
        '${AppConfig.apiUrl}/Schedule.php',
        queryParameters: {'day': day},
      );
      final data = res.data as Map<String, dynamic>;
      final schedules = (data['schedules'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final labels = (data['day_labels'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      if (!mounted) return;
      _dayCache[day] = schedules;
      setState(() {
        _schedules = schedules;
        _selectedDay = day;
        if (labels.isNotEmpty) _dayLabels = labels;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() { _error = 'Không thể tải lịch chiếu'; _isLoading = false; });
    }
  }

  // ★ C: Sort by air_time (nearest first)
  List<Map<String, dynamic>> get _filteredSchedules {
    List<Map<String, dynamic>> list;
    if (_currentFilter == 'all') {
      list = List.from(_schedules);
    } else {
      list = _schedules.where((s) {
        final type = (s['type'] ?? '').toString();
        switch (_currentFilter) {
          case 'series': return type == 'series' || type == 'tvshows';
          case 'hoathinh': return type == 'hoathinh';
          default: return true;
        }
      }).toList();
    }
    // Sort theo air_time
    list.sort((a, b) {
      final tA = (a['air_time'] ?? '99:99').toString().substring(0, 5);
      final tB = (b['air_time'] ?? '99:99').toString().substring(0, 5);
      return tA.compareTo(tB);
    });
    return list;
  }

  String _typeLabel(String t) {
    switch (t) {
      case 'series': return 'Phim Bộ';
      case 'hoathinh': return 'Anime';
      case 'tvshows': return 'TV Show';
      default: return t;
    }
  }

  String _filterLabel(String f) {
    switch (f) {
      case 'all': return 'Tất cả';
      case 'series': return 'Phim Bộ';
      case 'hoathinh': return 'Anime';
      default: return f;
    }
  }

  String _parseAirTime(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final s = raw.toString();
    if (s.length >= 5) return s.substring(0, 5);
    return s;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final body = Column(
      children: [
        // ★ B: Day tabs
        if (_dayLabels.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              itemCount: _dayLabels.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final d = _dayLabels[i];
                final idx = d['index'] ?? i;
                final label = d['label']?.toString() ?? 'Ngày ${i + 1}';
                final date = d['date']?.toString() ?? '';
                final isActive = idx == _selectedDay;
                return GestureDetector(
                  onTap: () {
                    if (idx == _selectedDay) return;
                    _loadSchedule(idx);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: isActive ? AppTheme.accent : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isActive ? AppTheme.accent : AppTheme.border,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            color: isActive ? const Color(0xFF1A1100) : AppTheme.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (date.isNotEmpty)
                          Text(
                            date.substring(5), // MM-DD
                            style: TextStyle(
                              color: isActive ? const Color(0xFF1A1100).withValues(alpha: 0.7) : AppTheme.textMuted,
                              fontSize: 9,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        const Divider(color: AppTheme.border, height: 1),

        // Category filters
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            children: ['all', 'series', 'hoathinh'].map((f) {
              final active = _currentFilter == f;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => setState(() => _currentFilter = f),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: active ? AppTheme.accent.withValues(alpha: 0.12) : Colors.transparent,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: active ? AppTheme.accent.withValues(alpha: 0.4) : AppTheme.border,
                      ),
                    ),
                    child: Text(
                      _filterLabel(f),
                      style: TextStyle(
                        color: active ? AppTheme.gold : AppTheme.textSub,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const Divider(color: AppTheme.border, height: 1),

        // Content
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
              : _error != null
                  ? Center(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Icon(Icons.calendar_today_outlined, size: 56, color: AppTheme.textMuted),
                        const SizedBox(height: 12),
                        Text(_error!, style: const TextStyle(color: AppTheme.textSub)),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () => _loadSchedule(_selectedDay),
                          child: const Text('Thử lại'),
                        ),
                      ]),
                    )
                  : _filteredSchedules.isEmpty
                      ? Center(
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Icon(
                              _schedules.isEmpty ? Icons.event_busy_outlined : Icons.search_off_outlined,
                              size: 56, color: AppTheme.textMuted,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _schedules.isEmpty ? 'Không có lịch chiếu ngày này' : 'Không có phim thể loại này',
                              style: const TextStyle(color: AppTheme.textSub, fontSize: 15),
                            ),
                          ]),
                        )
                      : RefreshIndicator(
                          onRefresh: () => _loadSchedule(_selectedDay),
                          color: AppTheme.accent,
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(14, 8, 14, 80),
                            itemCount: _filteredSchedules.length,
                            itemBuilder: (context, index) => _buildScheduleCard(_filteredSchedules[index]),
                          ),
                        ),
        ),
      ],
    );

    if (widget.isTab) return body;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Lịch Chiếu', style: TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
      ),
      body: body,
    );
  }

  Widget _buildScheduleCard(Map<String, dynamic> s) {
    final name = s['name']?.toString() ?? '';
    final originName = s['origin_name']?.toString() ?? '';
    final slug = s['slug']?.toString() ?? '';
    final thumb = s['thumb_url']?.toString() ?? '';
    final quality = s['quality']?.toString() ?? '';
    final type = s['type']?.toString() ?? '';
    final country = s['country_name']?.toString() ?? '';
    final year = s['year'];
    final airTime = _parseAirTime(s['air_time']?.toString());
    final note = s['note']?.toString() ?? '';
    final epCurrent = s['episode_current']?.toString() ?? '';
    final lastAdded = (s['last_added_episodes'] as int?) ?? 0;
    final isCompleted = s['is_completed'] == true;
    final movieId = s['id'];
    final epClean = epCurrent.replaceAll(RegExp(r'^[Tt]ậ?p?\s*'), '');

    return GestureDetector(
      onTap: () {
        if (movieId == null) return;
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => MovieDetailScreen(movieId: movieId, slug: slug),
        ));
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(
          children: [
            // Poster + time badge
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: thumb,
                    width: 70, height: 105,
                    fit: BoxFit.cover,
                    memCacheWidth: 140,
                    placeholder: (_, __) => Container(width: 70, height: 105, color: AppTheme.bgSurface),
                    errorWidget: (_, __, ___) => Container(
                      width: 70, height: 105, color: AppTheme.bgSurface,
                      child: const Icon(Icons.movie, color: AppTheme.textMuted),
                    ),
                  ),
                ),
                if (airTime.isNotEmpty)
                  Positioned(
                    top: 4, left: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.accent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.access_time, size: 10, color: Color(0xFF1A1100)),
                          const SizedBox(width: 2),
                          Text(airTime, style: const TextStyle(color: Color(0xFF1A1100), fontSize: 10, fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ),
                  ),
                if (isCompleted)
                  Positioned(
                    bottom: 4, left: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF22C55E),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('✓ HT', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w800)),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
                  if (originName.isNotEmpty)
                    Padding(padding: const EdgeInsets.only(top: 2),
                      child: Text(originName, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppTheme.textMuted, fontSize: 11))),
                  const SizedBox(height: 6),
                  // Pills
                  Wrap(
                    spacing: 4, runSpacing: 4,
                    children: [
                      if (quality.isNotEmpty) _pill(quality),
                      if (type.isNotEmpty) _pill(_typeLabel(type)),
                      if (country.isNotEmpty) _pill(country),
                      if (year != null) _pill('$year'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Episode status — ★ FIX: bỏ prefix "Tập" trùng
                  if (isCompleted)
                    Text('✓ Hoàn thành $epClean', style: const TextStyle(color: Color(0xFF22C55E), fontSize: 11, fontWeight: FontWeight.w600))
                  else if (lastAdded > 0 && epClean.isNotEmpty)
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Cập nhật tập $epClean', style: const TextStyle(color: AppTheme.accent, fontSize: 11, fontWeight: FontWeight.w600)),
                    ])
                  else if (epClean.isNotEmpty)
                    Text('Tập $epClean', style: const TextStyle(color: AppTheme.textSub, fontSize: 11)),
                ],
              ),
            ),
            // Arrow
            const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _pill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppTheme.border),
      ),
      child: Text(text, style: const TextStyle(color: AppTheme.textSub, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }
}
