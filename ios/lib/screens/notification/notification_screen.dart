import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../../config/app_config.dart';
import '../../config/theme.dart';
import '../../providers/auth_provider.dart';
import '../../providers/reminder_provider.dart';
import '../../widgets/header.dart';
import '../../widgets/bottom_nav.dart';
import '../home/home_screen.dart';
import '../auth/auth_screen.dart';
import '../actors/actors_list_screen.dart';
import '../../services/startapp_ad_service.dart';
import '../../widgets/startapp_banner_widget.dart';

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> with AutomaticKeepAliveClientMixin {
  final Dio _dio = Dio();
  String _tab = 'all'; // all | unread | read
  List<dynamic> _notifications = [];
  List<dynamic> _reminders = [];
  bool _isLoading = true;
  int _unreadCount = 0;
  int _navIndex = -1; // Không highlight tab nào (đây là màn hình riêng)

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Show interstitial when opening notification screen
      StartAppAdService.showInterstitialIfAllowed(context);
      final auth = context.read<AuthProvider>();
      if (auth.isLoggedIn) {
        _fetchData();
        // Đồng bộ reminders từ provider
        context.read<ReminderProvider>().fetchReminders();
      } else {
        setState(() => _isLoading = false);
      }
    });
  }

  Future<void> _fetchData() async {
    setState(() => _isLoading = true);
    try {
      final res = await _dio.get(
        '${AppConfig.apiUrl}/notifications.php',
        queryParameters: {'tab': _tab},
      );

      if (res.data['success'] == true) {
        setState(() {
          _notifications = res.data['notifications'] as List<dynamic>? ?? [];
          _reminders = res.data['reminders'] as List<dynamic>? ?? [];
          _unreadCount = res.data['unread_count'] as int? ?? 0;
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _markAsRead(int notifId) async {
    try {
      await _dio.post(
        '${AppConfig.apiUrl}/notifications.php',
        data: {'action': 'mark_read', 'id': notifId},
      );
      _fetchData(); // Refresh
    } catch (e) {
      // Error
    }
  }

  void _onNavSelected(int index) {
    if (index == _navIndex) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => HomeScreen(initialIndex: index)),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final auth = context.watch<AuthProvider>();
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    if (!auth.isLoggedIn) {
      return _buildNotLoggedIn();
    }

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Stack(
        children: [
          // Content
          Padding(
            padding: EdgeInsets.only(
              top: topPad + 56,
              left: 16,
              right: 16,
            ),
            child: _isLoading ? _buildLoading() : _buildContent(),
          ),

          // Header
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Header(
              onSearchTap: () => _onNavSelected(1),
              onWatchPartyTap: () {},
              onNotificationTap: () {},
              onActorsTap: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const ActorsListScreen()));
              },
              onAccountTap: () => _onNavSelected(3),
            ),
          ),

          // BottomNav
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Builder(
              builder: (context) {
                final auth = context.watch<AuthProvider>();
                return BottomNav(
                  currentIndex: _navIndex,
                  onTabSelected: _onNavSelected,
                  avatarUrl: auth.isLoggedIn ? (auth.user?['avatar']?.toString()) : null,
                );
              },
            ),
          ),
          // Banner ad above BottomNav
          const Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            child: StartAppBannerWidget(),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return RefreshIndicator(
      onRefresh: _fetchData,
      color: AppTheme.accent,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const Text(
            'Thông báo của tôi',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Xem thông báo từ admin, thông báo phim và các cập nhật quan trọng.',
            style: TextStyle(color: AppTheme.textSub, fontSize: 14),
          ),
          const SizedBox(height: 24),

          // Phim nhắc nhở
          _buildRemindersSection(),
          const SizedBox(height: 32),

          // Hộp thư thông báo
          _buildNotificationsSection(),
          const SizedBox(height: 80), // Spacer cho BottomNav
        ],
      ),
    );
  }

  Widget _buildRemindersSection() {
    // Ưu tiên data từ ReminderProvider (cập nhật realtime khi bấm nhắc nhở)
    final provider = context.watch<ReminderProvider>();
    final reminders = provider.reminders.isNotEmpty ? provider.reminders : _reminders;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Phim nhắc nhở của tôi',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 12),
        if (reminders.isEmpty)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.08), style: BorderStyle.solid, width: 1),
            ),
            child: const Text(
              'Bạn chưa bật nhắc nhở cho phim nào.',
              style: TextStyle(color: AppTheme.textSub),
            ),
          )
        else
          ...(reminders.map((r) => _buildReminderCard(r))),
      ],
    );
  }

  Widget _buildReminderCard(Map<String, dynamic> reminder) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CachedNetworkImage(
              imageUrl: reminder['thumb_url'] ?? '',
              width: 72,
              height: 96,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Container(
                color: AppTheme.bgCard,
                child: const Icon(Icons.movie, color: AppTheme.textMuted),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reminder['name'] ?? '',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                if (reminder['day_of_week'] != null || reminder['air_time'] != null)
                  Text(
                    '${_getDayName(reminder['day_of_week'])} · ${reminder['air_time'] ?? ''}',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  reminder['note'] ?? 'Nhắc khi có tập mới',
                  style: const TextStyle(
                    color: AppTheme.textSub,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getDayName(dynamic dayOfWeek) {
    if (dayOfWeek == null) return '';
    final days = ['Chủ Nhật', 'Thứ Hai', 'Thứ Ba', 'Thứ Tư', 'Thứ Năm', 'Thứ Sáu', 'Thứ Bảy'];
    final index = dayOfWeek is int ? dayOfWeek : int.tryParse(dayOfWeek.toString()) ?? 0;
    return days[index % 7];
  }

  Widget _buildNotificationsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Hộp thư thông báo',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 12),

        // Tabs
        Row(
          children: [
            _buildTabChip('Tất cả', 'all'),
            const SizedBox(width: 10),
            _buildTabChip('Chưa đọc${_unreadCount > 0 ? ' ($_unreadCount)' : ''}', 'unread'),
            const SizedBox(width: 10),
            _buildTabChip('Đã đọc', 'read'),
          ],
        ),
        const SizedBox(height: 16),

        // Notifications list
        if (_notifications.isEmpty)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.08), style: BorderStyle.solid),
            ),
            child: const Text(
              'Bạn chưa có thông báo nào.',
              style: TextStyle(color: AppTheme.textSub),
            ),
          )
        else
          ...(_notifications.map((n) => _buildNotificationCard(n))),
      ],
    );
  }

  Widget _buildTabChip(String label, String value) {
    final isActive = _tab == value;
    return GestureDetector(
      onTap: () {
        setState(() => _tab = value);
        _fetchData();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? AppTheme.accent : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isActive ? Colors.transparent : Colors.white.withOpacity(0.08),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? Colors.black : AppTheme.textSub,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildNotificationCard(Map<String, dynamic> notif) {
    final isUnread = (notif['is_read'] as int? ?? 1) == 0;
    final notifId = notif['id'] as int;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isUnread
              ? const Color(0x66E50914)
              : Colors.white.withOpacity(0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notif['title'] ?? '',
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        notif['kind'] ?? 'broadcast',
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                _formatDate(notif['created_at']),
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            notif['body'] ?? '',
            style: const TextStyle(
              color: AppTheme.textSub,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isUnread ? 'Chưa đọc' : 'Đã đọc',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 12,
            ),
          ),
          if (isUnread) ...[
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => _markAsRead(notifId),
              style: TextButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.1),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              child: const Text(
                'Đánh dấu đã đọc',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatDate(dynamic createdAt) {
    if (createdAt == null) return '';
    try {
      final date = DateTime.parse(createdAt.toString());
      return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return '';
    }
  }

  Widget _buildLoading() {
    return const Center(
      child: CircularProgressIndicator(color: AppTheme.accent),
    );
  }

  Widget _buildNotLoggedIn() {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.notifications_off_outlined, size: 72, color: AppTheme.textMuted),
            const SizedBox(height: 16),
            const Text(
              'Bạn cần đăng nhập để xem thông báo',
              style: TextStyle(color: AppTheme.textSub, fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AuthScreen()),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: const Color(0xFF1A1100),
              ),
              child: const Text('Đăng nhập'),
            ),
          ],
        ),
      ),
    );
  }
}
