import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../../config/app_config.dart';
import '../../config/theme.dart';
import '../../providers/auth_provider.dart';
import '../../services/watch_party_service.dart';
import '../../widgets/header.dart';
import '../../widgets/bottom_nav.dart';
import '../../services/image_cache_manager.dart';
import '../home/home_screen.dart';
import '../watch_room/watch_room_screen.dart';
import '../notification/notification_screen.dart';
import '../actors/actors_list_screen.dart';
import 'watch_party_manage_screen.dart';

/// Màn hình danh sách phòng xem chung (giống mobile web)
class WatchPartyScreen extends StatefulWidget {
  const WatchPartyScreen({super.key});

  @override
  State<WatchPartyScreen> createState() => _WatchPartyScreenState();
}

class _WatchPartyScreenState extends State<WatchPartyScreen> {
  final Dio _dio = Dio();
  String _sortFilter = 'new';
  List<dynamic> _rooms = [];
  bool _isLoading = true;
  int _navIndex = -1;

  @override
  void initState() {
    super.initState();
    _fetchRooms();
  }

  Future<void> _fetchRooms() async {
    setState(() => _isLoading = true);
    try {
      final res = await _dio.get(
        '${AppConfig.apiUrl}/watch_party_list.php',
        queryParameters: {'sort': _sortFilter},
      );
      setState(() {
        _rooms = res.data['rooms'] as List<dynamic>? ?? [];
        // Ưu tiên: live → waiting → ended
        _rooms.sort((a, b) {
          int priority(String s) => s == 'live' ? 0 : s == 'waiting' ? 1 : 2;
          return priority(a['status'] ?? '').compareTo(priority(b['status'] ?? ''));
        });
        _isLoading = false;
      });
    } catch (_) {
      setState(() => _isLoading = false);
    }
  }

  void _onNavSelected(int index) {
    if (index == _navIndex) return;
    // Navigate về HomeScreen với tab tương ứng
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => HomeScreen(initialIndex: index)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Stack(
        children: [
          // Content
          RefreshIndicator(
            onRefresh: _fetchRooms,
            color: AppTheme.accent,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // Hero section
                SliverToBoxAdapter(child: _buildHero()),

                // Filter section
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Phòng đang hoạt động',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      _buildFilterChips(),
                    ],
                  ),
                ),
              ),

              // Rooms list
              if (_isLoading)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _buildLoadingSkeleton(),
                      ),
                      childCount: 3,
                    ),
                  ),
                )
              else if (_rooms.isEmpty)
                SliverFillRemaining(child: _buildEmptyState())
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPad + 100),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _buildRoomCard(_rooms[i] as Map<String, dynamic>),
                      ),
                      childCount: _rooms.length,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Header cố định
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Header(
              onSearchTap: () => _onNavSelected(1),
              onWatchPartyTap: () {},
              onNotificationTap: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationScreen()));
              },
              onActorsTap: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const ActorsListScreen()));
              },
              onAccountTap: () => _onNavSelected(3),
            ),
          ),

          // BottomNav với spring animation
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Builder(
              builder: (context) {
                final auth = context.watch<AuthProvider>();
                return BottomNav(
                  currentIndex: _navIndex,
                  onTabSelected: _onNavSelected,
                    avatarUrl: auth.isLoggedIn ? (() {
                      final raw = auth.user?['avatar']?.toString() ?? '';
                      return raw.isNotEmpty && !raw.startsWith('http') ? '${AppConfig.baseUrl}$raw' : raw;
                    })() : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHero() {
    return Container(
      height: 300,
      margin: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 56), // Thêm 56 cho Header
      child: Stack(
        children: [
          // Background image
          Positioned.fill(
            child: CachedNetworkImage(
              imageUrl: '${AppConfig.baseUrl}/assets/images/live-cover2.webp',
              fit: BoxFit.cover,
              color: Colors.black.withOpacity(0.5),
              colorBlendMode: BlendMode.darken,
              cacheManager: AppImageCacheManager(),
              fadeInDuration: Duration.zero,
              errorWidget: (_, __, ___) => Container(color: AppTheme.bgCard),
            ),
          ),
          // Gradient overlay
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    AppTheme.bg.withOpacity(0.8),
                    AppTheme.bg,
                  ],
                  stops: const [0.0, 0.7, 1.0],
                ),
              ),
            ),
          ),
          // Content
          Positioned.fill(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.people_rounded, size: 64, color: AppTheme.accent),
                const SizedBox(height: 16),
                const Text(
                  'Xem Chung',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Cùng bạn bè xem phim, trò chuyện thời gian thực',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildActionButton(
                      icon: Icons.add_rounded,
                      label: 'Tạo phòng',
                      onTap: () {
                        // Tạo phòng từ trang chi tiết phim
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Vào trang chi tiết phim → bấm "Xem chung" để tạo phòng'),
                            duration: Duration(seconds: 3),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 12),
                    _buildActionButton(
                      icon: Icons.edit_rounded,
                      label: 'Quản lý',
                      isPrimary: false,
                      onTap: () {
                        Navigator.push(context, MaterialPageRoute(
                          builder: (_) => const WatchPartyManageScreen(),
                        ));
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isPrimary = true,
  }) {
    return Material(
      color: isPrimary
          ? AppTheme.accent
          : Colors.white.withOpacity(0.1),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: isPrimary ? const Color(0xFF1A1100) : AppTheme.textPrimary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: isPrimary ? const Color(0xFF1A1100) : AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Row(
        children: [
          _buildFilterChip('Mới nhất', 'new'),
          _buildFilterChip('Phổ biến', 'popular'),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String value) {
    final isActive = _sortFilter == value;
    return GestureDetector(
      onTap: () {
        setState(() => _sortFilter = value);
        _fetchRooms();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? Colors.white.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? AppTheme.textPrimary : AppTheme.textSub,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildRoomCard(Map<String, dynamic> room) {
    final status = room['status'] as String? ?? 'waiting';
    final hasPassword = (room['has_password'] as int?) == 1;
    final memberCount = room['member_count'] as int? ?? 0;
    final roomCode = room['room_code'] as String?;

    return GestureDetector(
      onTap: () {
        if (roomCode != null) {
          if (hasPassword) {
            _showPasswordDialog(roomCode);
          } else {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => WatchRoomScreen(roomCode: roomCode),
              ),
            );
          }
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Poster với badges
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: room['thumb_url'] ?? '',
                    fit: BoxFit.cover,
                    cacheManager: AppImageCacheManager(),
                    fadeInDuration: const Duration(milliseconds: 200),
                    fadeOutDuration: const Duration(milliseconds: 100),
                    errorWidget: (_, __, ___) => Container(
                      color: AppTheme.bgCard,
                      child: const Icon(Icons.movie, color: AppTheme.textMuted),
                    ),
                  ),
                  // Gradient overlay
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.8),
                        ],
                      ),
                    ),
                  ),
                  // Badges
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Row(
                      children: [
                        _buildStatusBadge(status),
                        if (hasPassword) ...[
                          const SizedBox(width: 6),
                          _buildPasswordBadge(),
                        ],
                      ],
                    ),
                  ),
                  // Member count
                  if (status == 'live')
                    Positioned(
                      bottom: 10,
                      right: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white.withOpacity(0.2)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.people, size: 12, color: Colors.white),
                            const SizedBox(width: 4),
                            Text(
                              '$memberCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Info
          Row(
            children: [
              // Avatar
              ClipOval(
                child: Container(
                  width: 36,
                  height: 36,
                  color: AppTheme.bgCard,
                  child: room['avatar'] != null && (room['avatar'] as String).isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: (room['avatar'] as String).startsWith('http')
                              ? room['avatar']
                              : '${AppConfig.baseUrl}/${room['avatar']}',
                          fit: BoxFit.cover,
                          cacheManager: AppImageCacheManager(),
                          fadeInDuration: Duration.zero,
                          errorWidget: (_, __, ___) => const Icon(
                            Icons.person,
                            color: AppTheme.textMuted,
                            size: 20,
                          ),
                        )
                      : const Icon(Icons.person, color: AppTheme.textMuted, size: 20),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      room['title'] ?? 'Untitled',
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Chủ phòng: ${room['username'] ?? 'Unknown'}',
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    Color bgColor, textColor;
    String label;
    bool showDot = false;

    switch (status) {
      case 'live':
        bgColor = const Color(0xCCF5C518);
        textColor = Colors.white;
        label = 'LIVE';
        showDot = true;
        break;
      case 'waiting':
        bgColor = Colors.black.withOpacity(0.6);
        textColor = const Color(0xFFfbbf24);
        label = 'Chờ';
        break;
      default:
        bgColor = Colors.black.withOpacity(0.6);
        textColor = const Color(0xFF94a3b8);
        label = 'Kết thúc';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          if (showDot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: textColor,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPasswordBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x26fb923c),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0x4Dfb923c)),
      ),
      child: const Icon(Icons.lock, size: 10, color: Color(0xFFfb923c)),
    );
  }

  void _showPasswordDialog(String roomCode) {
    final passwordController = TextEditingController();
    String? errorText;
    bool isLoading = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> verify() async {
            final password = passwordController.text.trim();
            if (password.isEmpty) {
              setDialogState(() => errorText = 'Vui lòng nhập mật khẩu');
              return;
            }
            if (password.length < 4) {
              setDialogState(() => errorText = 'Mật khẩu tối thiểu 4 ký tự');
              return;
            }

            setDialogState(() {
              errorText = null;
              isLoading = true;
            });

            final service = WatchPartyService();
            final result = await service.verifyPassword(roomCode: roomCode, password: password);

            if (result['success'] == true) {
              if (mounted) {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => WatchRoomScreen(roomCode: roomCode)),
                );
              }
            } else {
              setDialogState(() {
                errorText = result['error']?.toString() ?? 'Mật khẩu không đúng';
                isLoading = false;
              });
              passwordController.selection = TextSelection(baseOffset: 0, extentOffset: passwordController.text.length);
            }
          }

          return AlertDialog(
            backgroundColor: AppTheme.bgCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Icon(Icons.lock, size: 20, color: const Color(0xFFfb923c)),
                const SizedBox(width: 8),
                Text('Phòng có mật khẩu', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  autofocus: true,
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Nhập mật khẩu',
                    hintStyle: TextStyle(color: AppTheme.textMuted),
                    filled: true,
                    fillColor: AppTheme.bgSurface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppTheme.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppTheme.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppTheme.accent),
                    ),
                    errorText: errorText,
                    prefixIcon: Icon(Icons.key, size: 18, color: AppTheme.textMuted),
                  ),
                  onSubmitted: (_) => verify(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Hủy', style: TextStyle(color: AppTheme.textMuted)),
              ),
              ElevatedButton(
                onPressed: isLoading ? null : verify,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: isLoading
                    ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text('Vào phòng', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLoadingSkeleton() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.people_outline_rounded,
            size: 72,
            color: AppTheme.textMuted.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          const Text(
            'Chưa có phòng nào',
            style: TextStyle(
              color: AppTheme.textSub,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tạo phòng mới để xem cùng bạn bè',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
