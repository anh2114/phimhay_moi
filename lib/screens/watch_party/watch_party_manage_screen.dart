import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../../config/app_config.dart';
import '../../config/theme.dart';
import '../../providers/auth_provider.dart';
import '../../services/watch_party_service.dart';
import '../watch_room/watch_room_screen.dart';
import '../../services/image_cache_manager.dart';

/// Màn hình quản lý phòng xem chung (giống web quan-ly-xem-chung.php)
class WatchPartyManageScreen extends StatefulWidget {
  const WatchPartyManageScreen({super.key});

  @override
  State<WatchPartyManageScreen> createState() => _WatchPartyManageScreenState();
}

class _WatchPartyManageScreenState extends State<WatchPartyManageScreen> {
  final Dio _dio = Dio();
  final WatchPartyService _service = WatchPartyService();
  List<dynamic> _rooms = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchMyRooms();
  }

  Future<void> _fetchMyRooms() async {
    setState(() => _isLoading = true);
    try {
      final auth = context.read<AuthProvider>();
      final userId = auth.user?['user_id'] ?? 0;
      final res = await _dio.get(
        '${AppConfig.apiUrl}/watch_party_list.php',
        queryParameters: {'my_rooms': '1', 'user_id': userId},
      );
      setState(() {
        _rooms = res.data['rooms'] as List<dynamic>? ?? [];
        _isLoading = false;
      });
    } catch (_) {
      setState(() => _isLoading = false);
    }
  }

  int get _totalRooms => _rooms.length;
  int get _activeRooms => _rooms.where((r) => r['status'] == 'live' || r['status'] == 'waiting').length;
  int get _endedRooms => _rooms.where((r) => r['status'] == 'ended').length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            _buildHeader(),
            // Content
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
                  : RefreshIndicator(
                      onRefresh: _fetchMyRooms,
                      color: AppTheme.accent,
                      child: _rooms.isEmpty ? _buildEmptyState() : _buildContent(),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Quản Lý Xem Chung',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                ),
                Text(
                  'Xem danh sách phòng của bạn',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stats row
          _buildStatsRow(),
          const SizedBox(height: 24),
          // Room list
          ..._rooms.map((room) => _buildRoomCard(room as Map<String, dynamic>)),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    return Row(
      children: [
        _buildStatCard('Tổng số phòng', '$_totalRooms', Icons.grid_view_rounded, Colors.white),
        const SizedBox(width: 12),
        _buildStatCard('Đang hoạt động', '$_activeRooms', Icons.play_circle_rounded, AppTheme.accent),
        const SizedBox(width: 12),
        _buildStatCard('Đã kết thúc', '$_endedRooms', Icons.stop_circle_rounded, AppTheme.textMuted),
      ],
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color valueColor) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: AppTheme.textMuted),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(color: valueColor, fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildRoomCard(Map<String, dynamic> room) {
    final roomCode = room['room_code']?.toString() ?? '';
    final title = room['title']?.toString() ?? '';
    final epName = room['ep_name']?.toString() ?? '';
    final status = room['status']?.toString() ?? '';
    final posterUrl = room['thumb_url']?.toString() ?? '';
    final createdAt = room['created_at']?.toString() ?? '';
    final roomId = room['id'] as int? ?? 0;

    final isLive = status == 'live';
    final isWaiting = status == 'waiting';
    final isEnded = status == 'ended';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Poster
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: posterUrl.startsWith('http') ? posterUrl : '${AppConfig.baseUrl}$posterUrl',
                  width: 48, height: 68,
                  fit: BoxFit.cover,
                  cacheManager: AppImageCacheManager(),
                  fadeInDuration: Duration.zero,
                  errorWidget: (_, __, ___) => Container(
                    width: 48, height: 68,
                    color: AppTheme.bgSurface,
                    child: const Icon(Icons.movie_rounded, color: Colors.white24, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (epName.isNotEmpty)
                      Text('${epName.toLowerCase().startsWith('tập') ? epName : 'Tập: $epName'}', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                    const SizedBox(height: 4),
                    // Room code
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Text(roomCode, style: TextStyle(color: AppTheme.accent, fontSize: 11, fontWeight: FontWeight.w600, fontFamily: 'monospace')),
                    ),
                  ],
                ),
              ),
              // Status badge
              _buildStatusBadge(status),
            ],
          ),
          const SizedBox(height: 12),
          // Actions
          Row(
            children: [
              // Created at
              Expanded(
                child: Text(createdAt, style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
              ),
              // Action buttons
              if (!isEnded) ...[
                // Vào phòng
                _buildActionButton(
                  icon: Icons.play_arrow_rounded,
                  label: 'Vào phòng',
                  color: AppTheme.accent,
                  onTap: () {
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => WatchRoomScreen(roomCode: roomCode),
                    ));
                  },
                ),
                const SizedBox(width: 8),
                // Kết thúc
                _buildActionButton(
                  icon: Icons.stop_rounded,
                  label: 'Kết thúc',
                  color: Colors.redAccent,
                  onTap: () => _endRoom(roomCode),
                ),
                const SizedBox(width: 8),
              ],
              // Xóa
              _buildActionButton(
                icon: Icons.delete_rounded,
                label: '',
                color: AppTheme.textMuted,
                onTap: () => _deleteRoom(roomId, title),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    Color color;
    String label;
    bool showDot = false;

    switch (status) {
      case 'live':
        color = AppTheme.accent;
        label = 'LIVE';
        showDot = true;
        break;
      case 'waiting':
        color = const Color(0xFFfbbf24);
        label = 'ĐANG CHỜ';
        break;
      default:
        color = AppTheme.textMuted;
        label = 'ĐÃ KẾT THÚC';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 4),
          ],
          Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildActionButton({required IconData icon, required String label, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: label.isNotEmpty ? 10 : 8, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 4),
              Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline_rounded, size: 64, color: AppTheme.textMuted.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          const Text('Bạn chưa tạo phòng xem chung nào', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Hãy vào trang chi tiết phim và tạo phòng xem chung', style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.accent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text('Chọn phim tạo phòng', style: TextStyle(color: Colors.black, fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _endRoom(String roomCode) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: const Text('Kết thúc phòng?', style: TextStyle(color: Colors.white)),
        content: Text('Khán giả sẽ không thể xem tiếp.', style: TextStyle(color: AppTheme.textSub)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Hủy', style: TextStyle(color: AppTheme.textMuted))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Kết thúc', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirm != true) return;

    final success = await _service.endRoom(roomCode);
    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã kết thúc phòng'), backgroundColor: Colors.green));
      _fetchMyRooms();
    }
  }

  Future<void> _deleteRoom(int roomId, String title) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: const Text('Xóa phòng?', style: TextStyle(color: Colors.white)),
        content: Text('Không thể khôi phục. Xóa "$title"?', style: TextStyle(color: AppTheme.textSub)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Hủy', style: TextStyle(color: AppTheme.textMuted))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xóa', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirm != true) return;

    final success = await _service.deleteRoom(roomId);
    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã xóa phòng'), backgroundColor: Colors.green));
      _fetchMyRooms();
    }
  }
}
