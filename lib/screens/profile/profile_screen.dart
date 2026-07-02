import 'dart:ui' as ui;
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phimhay_app/services/profile_service.dart';
import 'package:provider/provider.dart';
import 'package:phimhay_app/config/app_config.dart';
import 'package:phimhay_app/services/api_client.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/providers/auth_provider.dart';
import 'package:phimhay_app/screens/auth/auth_screen.dart';
import 'package:phimhay_app/screens/home/home_screen.dart';
import 'package:phimhay_app/screens/movie_detail/movie_detail_screen.dart';
import 'package:phimhay_app/screens/watch/watch_screen.dart';
import 'package:phimhay_app/screens/search/search_screen.dart';
import 'package:phimhay_app/screens/schedule/schedule_screen.dart';
import 'package:phimhay_app/screens/list/list_screen.dart';
import 'package:phimhay_app/widgets/bottom_nav.dart';
import 'package:phimhay_app/services/smartlink_service.dart';

class ProfileScreen extends StatefulWidget {
  final bool isTab;
  const ProfileScreen({super.key, this.isTab = false});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  final ProfileService _profileService = ProfileService();
  int _navIndex = 4;
  String _currentTab = 'overview';
  bool _isLoading = true;
  bool _menuOpen = false;
  String? _error;
  bool _wasLoggedIn = false; // Track trạng thái login trước đó

  @override
  bool get wantKeepAlive => widget.isTab; // Giữ state khi là tab
  late AnimationController _glassCtrl;
  late Animation<double> _glassAnim;

  Map<String, dynamic>? _profileData;
  List<dynamic> _recentMovies = [];
  List<dynamic> _recentFavs = [];
  List<dynamic> _favorites = [];
  List<dynamic> _history = [];
  List<dynamic> _comments = [];

  final _emailCtrl = TextEditingController();
  final _avatarCtrl = TextEditingController();
  final _oldPassCtrl = TextEditingController();
  final _newPassCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();
  bool _isSaving = false;
  String? _successMsg;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _glassCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _glassAnim = CurvedAnimation(parent: _glassCtrl, curve: Curves.easeOutCubic);

    // Lấy version từ package_info
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = info.version);
    });

    // Load profile nếu đã login
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      _wasLoggedIn = auth.isLoggedIn;
      if (auth.isLoggedIn) {
        _loadTab('overview');
      } else {
        setState(() => _isLoading = false);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Kiểm tra khi auth state thay đổi
    final auth = context.watch<AuthProvider>();
    final isNowLoggedIn = auth.isLoggedIn;

    // Nếu vừa login (từ false → true) → reload data
    if (isNowLoggedIn && !_wasLoggedIn) {
      _wasLoggedIn = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadTab('overview');
      });
    }
    // Nếu vừa logout (từ true → false) → reset
    else if (!isNowLoggedIn && _wasLoggedIn) {
      _wasLoggedIn = false;
      setState(() {
        _profileData = null;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _glassCtrl.dispose();
    _emailCtrl.dispose();
    _avatarCtrl.dispose();
    _oldPassCtrl.dispose();
    _newPassCtrl.dispose();
    _confirmPassCtrl.dispose();
    super.dispose();
  }

  void _switchTab(String tab) {
    if (tab == _currentTab) return;
    _loadTab(tab);
  }

  Future<void> _openAdminWebView() async {
    if (!mounted) return;

    // Inject auth token vào WebView
    final token = ApiClient.token;
    final adminUrl = token != null && token.isNotEmpty
        ? '${AppConfig.baseUrl}/admin/?auth_token=$token'
        : '${AppConfig.baseUrl}/admin/';

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('Bảng Quản Trị'),
            backgroundColor: AppTheme.bg,
            foregroundColor: AppTheme.textPrimary,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri(adminUrl),
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
              useWideViewPort: true,
              loadWithOverviewMode: true,
            ),
          ),
        ),
      ),
    );
  }

  void _onNavSelected(int index) {
    if (widget.isTab || index == _navIndex) return;
    setState(() => _navIndex = index);
    Widget screen;
    switch (index) {
      case 0: screen = const HomeScreen(); break;
      case 1: screen = const SearchScreen(); break;
      case 2: screen = const ScheduleScreen(); break;
      case 3: screen = const ListScreen(); break;
      default: return;
    }
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => screen,
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
        transitionDuration: const Duration(milliseconds: 250),
      ),
    );
  }

  Future<void> _loadTab(String tab) async {
    setState(() { _currentTab = tab; _isLoading = true; _error = null; _successMsg = null; });

    // Dùng data local từ auth_provider thay vì gọi API
    final auth = context.read<AuthProvider>();
    final userData = auth.user;

    if (userData != null) {
      setState(() {
        _profileData = {
          'user': userData,
          'stats': {'favorites': 0, 'history': 0, 'comments': 0},
        };
        _recentMovies = [];
        _recentFavs = [];
        _favorites = [];
        _history = [];
        _comments = [];
        _isLoading = false;
        if (tab == 'settings') {
          _emailCtrl.text = userData['email']?.toString() ?? '';
          _avatarCtrl.text = userData['avatar']?.toString() ?? '';
        }
      });
    } else {
      setState(() { _error = 'Không có dữ liệu người dùng'; _isLoading = false; });
    }

    // Thử load thêm data từ server (fire-and-forget, không block UI)
    _loadTabFromServer(tab);
  }

  Future<void> _loadTabFromServer(String tab) async {
    try {
      final data = await _profileService.fetchProfile(tab);
      if (!mounted) return;
      setState(() {
        _profileData = data;
        _recentMovies = (data['recent'] as List<dynamic>?) ?? [];
        _recentFavs = (data['recent_favorites'] as List<dynamic>?) ?? [];
        _favorites = (data['favorites'] as List<dynamic>?) ?? [];
        _history = (data['history'] as List<dynamic>?) ?? [];
        _comments = (data['comments'] as List<dynamic>?) ?? [];
        if (tab == 'settings') {
          final u = data['user'] as Map<String, dynamic>?;
          _emailCtrl.text = u?['email']?.toString() ?? '';
          _avatarCtrl.text = u?['avatar']?.toString() ?? '';
        }
      });
    } catch (_) {
      // Bỏ qua lỗi — data local vẫn hiển thị
    }
  }

  String _timeAgo(String? s) {
    if (s == null || s.isEmpty) return '';
    final dt = DateTime.tryParse(s);
    if (dt == null) return '';
    final d = DateTime.now().difference(dt);
    if (d.inDays > 0) return '${d.inDays} ngày trước';
    if (d.inHours > 0) return '${d.inHours} giờ trước';
    if (d.inMinutes > 0) return '${d.inMinutes} phút trước';
    return 'Vừa xong';
  }

  String _fmtPos(int sec) {
    if (sec < 15) return '';
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    return h > 0 ? '${h}h${m.toString().padLeft(2, '0')}' : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Cần thiết cho AutomaticKeepAliveClientMixin
    final auth = context.watch<AuthProvider>();
    final body = auth.isLoggedIn ? _buildProfile(auth) : _buildNotLoggedIn();

    if (widget.isTab) return body;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Stack(
        children: [
          body,
          // Bottom nav overlay
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

  Widget _buildNotLoggedIn() {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return SafeArea(
      child: Column(
        children: [
          // Header đã xóa bỏ dòng 'Tài khoản' dư thừa
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(width: 96, height: 96, decoration: BoxDecoration(shape: BoxShape.circle, color: AppTheme.bgCard, border: Border.all(color: AppTheme.border, width: 2)),
                    child: const Icon(Icons.person_outline_rounded, size: 52, color: AppTheme.textMuted)),
                  const SizedBox(height: 24),
                  const Text('Bạn chưa đăng nhập', style: TextStyle(color: AppTheme.textPrimary, fontSize: 22, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  const Text('Đăng nhập để đồng bộ dữ liệu và trải nghiệm tốt hơn', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSub, fontSize: 14, height: 1.5)),
                  const SizedBox(height: 32),
                  GestureDetector(
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AuthScreen())),
                    child: Container(width: double.infinity, height: 52,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFFE59A), Color(0xFFF5C84C)]),
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: [BoxShadow(color: AppTheme.accent.withValues(alpha: 0.28), blurRadius: 20, offset: const Offset(0, 8))],
                      ),
                      child: const Center(child: Text('Đăng nhập / Đăng ký', style: TextStyle(color: Color(0xFF1A1100), fontWeight: FontWeight.w800, fontSize: 16))),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          if (!widget.isTab) SizedBox(height: bottomPad + 80),
        ],
      ),
    );
  }

  Widget _buildProfile(AuthProvider auth) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    if (_isLoading && _profileData == null) {
      return SafeArea(child: Center(child: Padding(
        padding: EdgeInsets.only(bottom: bottomPad + 80),
        child: const CircularProgressIndicator(color: AppTheme.accent),
      )));
    }
    if (_error != null && _profileData == null) {
      return SafeArea(child: Center(child: Padding(
        padding: EdgeInsets.only(bottom: bottomPad + 80),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.error_outline, size: 48, color: AppTheme.textMuted),
          const SizedBox(height: 12), Text(_error!, style: const TextStyle(color: AppTheme.textSub)),
          const SizedBox(height: 16), ElevatedButton(onPressed: () => _loadTab('overview'), child: const Text('Thử lại')),
        ]),
      )));
    }

    final uData = _profileData?['user'] as Map<String, dynamic>? ?? {};
    final stats = _profileData?['stats'] as Map<String, dynamic>? ?? {};
    final username = uData['username']?.toString() ?? auth.user?['username'] ?? 'Người dùng';
    final email = uData['email']?.toString() ?? '';
    final avatar = uData['avatar']?.toString() ?? '';
    final role = uData['role']?.toString() ?? 'user';
    final isAdmin = role == 'admin';
    final initial = username.isNotEmpty ? username[0].toUpperCase() : 'U';
    final lastLogin = _timeAgo(uData['last_login']?.toString());

    return SafeArea(
      child: Column(
        children: [
          // ── Scrollable body ──
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _loadTab(_currentTab),
              color: AppTheme.accent,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(16, 0, 16, widget.isTab ? 16 : bottomPad + 100),
                child: AnimatedBuilder(
                animation: _glassAnim,
                builder: (context, child) {
                  final scale = 1.0 - _glassAnim.value * 0.02;
                  final opacity = 1.0 - _glassAnim.value * 0.15;
                  return Transform.scale(
                    scale: scale,
                    child: Opacity(opacity: opacity, child: child),
                  );
                },
                child: Column(
                  children: [
                    _buildSummaryCard(username, email, avatar, initial, isAdmin, lastLogin, stats),
                    const SizedBox(height: 12),
                    _buildMenuToggle(),
                    const SizedBox(height: 12),
                    if (_menuOpen) _buildTabGrid(isAdmin),
                    if (_currentTab != 'overview') ...[
                      const SizedBox(height: 4),
                      _glassTap(
                        onTap: () => _switchTab('overview'),
                        child: Padding(padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(children: [
                            const Icon(Icons.arrow_back_ios_rounded, size: 14, color: AppTheme.accent),
                            const SizedBox(width: 4),
                            Text('Quay lại trang cá nhân', style: TextStyle(color: AppTheme.accent, fontSize: 13, fontWeight: FontWeight.w600)),
                          ])),
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (_isLoading)
                      const Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator(color: AppTheme.accent))
                    else
                      _buildTabContent(),
                    const SizedBox(height: 20),
                    _buildAboutSection(),
                    const SizedBox(height: 80), // Spacer cho BottomNav
                  ],
                ),
              ),
            ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Summary card ──
  Widget _buildSummaryCard(String username, String email, String avatar, String initial,
      bool isAdmin, String lastLogin, Map<String, dynamic> stats) {
    return _glassCard(
      child: Column(children: [
        Row(children: [
          Stack(children: [
            Container(width: 72, height: 72,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppTheme.accent, width: 2),
                boxShadow: [BoxShadow(color: AppTheme.accent.withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 4))],
              ),
              child: ClipOval(child: avatar.isNotEmpty
                  ? CachedNetworkImage(imageUrl: avatar, fit: BoxFit.cover, errorWidget: (_, __, ___) => _avatarFallback(initial))
                  : _avatarFallback(initial)),
            ),
            if (isAdmin)
              Positioned(bottom: 0, right: 0,
                child: Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFE50914), borderRadius: BorderRadius.circular(999), border: Border.all(color: AppTheme.bgCard, width: 2)),
                  child: const Text('ADMIN', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w900))),
              ),
          ]),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(username, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.w800), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (email.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Row(children: [
              const Icon(Icons.email_outlined, size: 12, color: AppTheme.textMuted),
              const SizedBox(width: 4),
              Expanded(child: Text(email, style: const TextStyle(color: AppTheme.textMuted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ])),
            if (lastLogin.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Row(children: [
              const Icon(Icons.access_time_rounded, size: 12, color: AppTheme.textMuted),
              const SizedBox(width: 4),
              Text(lastLogin, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            ])),
          ])),
        ]),
        const SizedBox(height: 14),
        Container(padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(color: AppTheme.bgSurface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _statItem(Icons.favorite_rounded, 'Yêu thích', '${stats['favorites'] ?? 0}'),
            _vDiv(),
            _statItem(Icons.play_circle_outline_rounded, 'Đã xem', '${stats['history'] ?? 0}'),
            _vDiv(),
            _statItem(Icons.chat_bubble_outline_rounded, 'Bình luận', '${stats['comments'] ?? 0}'),
          ]),
        ),
      ]),
    );
  }

  // ── Menu toggle ──
  Widget _buildMenuToggle() {
    return _glassBtnRow(
      child: Row(children: [
        const Text('☰', style: TextStyle(fontSize: 18)),
        const SizedBox(width: 10),
        const Expanded(child: Text('Hiển thị thêm', style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700))),
        AnimatedRotation(turns: _menuOpen ? 0.5 : 0, duration: const Duration(milliseconds: 200),
          child: const Icon(Icons.expand_more_rounded, color: AppTheme.textMuted)),
      ]),
      onTap: () => setState(() => _menuOpen = !_menuOpen),
    );
  }

  // ── Tab grid ──
  Widget _buildTabGrid(bool isAdmin) {
    final tabs = <_TabDef>[
      _TabDef('Tổng quan', Icons.dashboard_rounded, 'overview'),
      _TabDef('Yêu thích', Icons.favorite_rounded, 'favorites'),
      _TabDef('Lịch sử', Icons.history_rounded, 'history'),
      _TabDef('Bình luận', Icons.chat_bubble_rounded, 'comments'),
      _TabDef('Cài đặt', Icons.settings_rounded, 'settings'),
      _TabDef('Bảo mật', Icons.shield_rounded, 'security'),
      if (isAdmin) _TabDef('Bảng Quản Trị', Icons.admin_panel_settings_rounded, 'admin'),
      _TabDef('Đăng xuất', Icons.logout_rounded, 'logout_action'),
    ];
    return GridView.count(
      crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 3.5, // Tăng từ 4.5 lên 3.5 để tránh cắt icon
      children: tabs.map((t) => _tabBtn(t.label, t.icon, t.tab)).toList(),
    );
  }

  Widget _tabBtn(String label, IconData icon, String tab) {
    final active = _currentTab == tab;
    return _glassBtn(
      tab == 'admin' ? () => _openAdminWebView() : (tab == 'logout_action' ? _confirmLogout : () => _switchTab(tab)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), // Giảm vertical padding từ 12 xuống 8
        decoration: BoxDecoration(
          color: tab == 'logout_action'
              ? Colors.redAccent.withValues(alpha: 0.1)
              : (active ? AppTheme.accent.withValues(alpha: 0.1) : AppTheme.bgCard),
          border: Border.all(
            color: tab == 'logout_action'
                ? Colors.redAccent.withValues(alpha: 0.4)
                : (active ? AppTheme.accent.withValues(alpha: 0.4) : AppTheme.border)
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: tab == 'logout_action' ? Colors.redAccent : (active ? AppTheme.gold : AppTheme.textMuted)),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: TextStyle(
            color: tab == 'logout_action'
                ? Colors.redAccent
                : (active ? AppTheme.gold : AppTheme.textPrimary),
            fontSize: 14,
            fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )),
          if (active)
            Container(width: 6, height: 6,
              decoration: const BoxDecoration(color: AppTheme.accent, shape: BoxShape.circle)),
        ]),
      ),
    );
  }

  // ── Tab content ──
  Widget _buildTabContent() {
    switch (_currentTab) {
      case 'overview': return _buildOverview();
      case 'favorites': return _buildFavorites();
      case 'history': return _buildHistory();
      case 'comments': return _buildComments();
      case 'settings': return _buildSettings();
      case 'security': return _buildSecurity();
      default: return const SizedBox.shrink();
    }
  }

  Widget _buildOverview() {
    return Column(children: [
      _secHeader('🕐 Xem Gần Đây'),
      if (_recentMovies.isEmpty) _emptyBox('Chưa có lịch sử xem phim.')
      else _recentGrid(_recentMovies),
      const SizedBox(height: 20),
      _secHeader('❤️ Yêu Thích Gần Đây'),
      if (_recentFavs.isEmpty) _emptyBox('Chưa có phim yêu thích.')
      else _posterGrid(_recentFavs),
    ]);
  }

  Widget _secHeader(String t) => Padding(padding: const EdgeInsets.only(bottom: 12),
    child: Row(children: [Text(t, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700))]));

  Widget _emptyBox(String msg) => Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 30),
    decoration: BoxDecoration(color: AppTheme.bgCard, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(12)),
    child: Text(msg, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSub, fontSize: 13)));

  Widget _posterGrid(List<dynamic> items) {
    return SizedBox(height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal, itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final m = items[i]; final slug = m['slug']?.toString() ?? ''; final name = m['name']?.toString() ?? '';
          final thumb = m['thumb_url']?.toString() ?? ''; final quality = m['quality']?.toString() ?? '';
          return _glassTap(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MovieDetailScreen(slug: slug))),
            child: SizedBox(width: 110, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Stack(children: [
                ClipRRect(borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(imageUrl: thumb, width: double.infinity, height: double.infinity, fit: BoxFit.cover,
                    placeholder: (_, __) => Container(color: AppTheme.bgCard),
                    errorWidget: (_, __, ___) => Container(color: AppTheme.bgCard, child: const Icon(Icons.movie, color: AppTheme.textMuted)))),
                if (quality.isNotEmpty) Positioned(top: 4, left: 4,
                  child: Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(color: AppTheme.accent, borderRadius: BorderRadius.circular(4)),
                    child: Text(quality, style: const TextStyle(color: Color(0xFF1A1100), fontSize: 9, fontWeight: FontWeight.w700)))),
              ])),
              const SizedBox(height: 6),
              Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.w600)),
            ])),
          );
        },
      ),
    );
  }

  /// Grid phim gần đây — tap vào mở WatchScreen trực tiếp
  Widget _recentGrid(List<dynamic> items) {
    return SizedBox(height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal, itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final m = items[i];
          final movieId = (m['id'] as int?) ?? 0;
          final slug = m['slug']?.toString() ?? ''; final name = m['name']?.toString() ?? '';
          final thumb = m['thumb_url']?.toString() ?? ''; final quality = m['quality']?.toString() ?? '';
          final episodeId = (m['episode_id'] as int?) ?? 0;
          final serverIdx = (m['server_idx'] as int?) ?? 0;
          final pos = (m['position'] as int?) ?? 0;
          final epName = m['ep_name']?.toString() ?? '';
          return _glassTap(
            onTap: () => SmartlinkService.showSmartlinkBeforeAction(context, onDone: () => Navigator.push(context, MaterialPageRoute(builder: (_) => WatchScreen(
              movieId: movieId,
              episodeId: episodeId > 0 ? episodeId : 1,
              serverIdx: serverIdx,
              movieSlug: slug,
              movieTitle: name,
              initialPosition: pos,
            )))),
            child: SizedBox(width: 110, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Stack(children: [
                ClipRRect(borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(imageUrl: thumb, width: double.infinity, height: double.infinity, fit: BoxFit.cover,
                    placeholder: (_, __) => Container(color: AppTheme.bgCard),
                    errorWidget: (_, __, ___) => Container(color: AppTheme.bgCard, child: const Icon(Icons.movie, color: AppTheme.textMuted)))),
                if (quality.isNotEmpty) Positioned(top: 4, left: 4,
                  child: Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(color: AppTheme.accent, borderRadius: BorderRadius.circular(4)),
                    child: Text(quality, style: const TextStyle(color: Color(0xFF1A1100), fontSize: 9, fontWeight: FontWeight.w700)))),
                // Badge tập đang xem
                if (epName.isNotEmpty) Positioned(bottom: 4, left: 4, right: 4,
                  child: Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                    child: Text('${epName.toLowerCase().startsWith('tập') ? epName : 'Tập $epName'}${pos > 0 ? ' · ${_fmtPos(pos)}' : ''}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)))),
              ])),
              const SizedBox(height: 6),
              Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.w600)),
            ])),
          );
        },
      ),
    );
  }

  Widget _buildFavorites() {
    if (_favorites.isEmpty) {
      return _glassCard(child: Padding(padding: const EdgeInsets.symmetric(vertical: 40), child: Column(children: [
        const Text('💔', style: TextStyle(fontSize: 40)), const SizedBox(height: 8),
        const Text('Chưa có phim yêu thích nào.', style: TextStyle(color: AppTheme.textSub, fontSize: 13)), const SizedBox(height: 16),
        _glassBtnRow(onTap: () => Navigator.pop(context), child: Container(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          decoration: BoxDecoration(color: AppTheme.accent, borderRadius: BorderRadius.circular(999)),
          child: const Text('Khám phá phim', style: TextStyle(color: Color(0xFF1A1100), fontWeight: FontWeight.w700, fontSize: 13)))),
      ])));
    }
    return Padding(padding: const EdgeInsets.only(bottom: 20), child: GridView.builder(
      shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 0.65),
      itemCount: _favorites.length,
      itemBuilder: (_, i) {
        final m = _favorites[i]; final slug = m['slug']?.toString() ?? ''; final name = m['name']?.toString() ?? '';
        final thumb = m['thumb_url']?.toString() ?? ''; final quality = m['quality']?.toString() ?? ''; final year = m['year'];
        return _glassTap(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MovieDetailScreen(slug: slug))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Stack(children: [
              ClipRRect(borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(imageUrl: thumb, width: double.infinity, height: double.infinity, fit: BoxFit.cover,
                  placeholder: (_, __) => Container(color: AppTheme.bgCard),
                  errorWidget: (_, __, ___) => Container(color: AppTheme.bgCard, child: const Icon(Icons.movie, color: AppTheme.textMuted)))),
              if (quality.isNotEmpty) Positioned(top: 4, left: 4,
                child: Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(color: AppTheme.accent, borderRadius: BorderRadius.circular(4)),
                  child: Text(quality, style: const TextStyle(color: Color(0xFF1A1100), fontSize: 9, fontWeight: FontWeight.w700)))),
            ])),
            const SizedBox(height: 4),
            Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.w600)),
            if (year != null) Text('$year', style: const TextStyle(color: AppTheme.textMuted, fontSize: 10)),
          ]));
      },
    ));
  }

  Widget _buildHistory() {
    if (_history.isEmpty) return _emptyBox('Chưa có lịch sử xem phim.');
    return Column(children: _history.map((m) {
      final movieId = (m['id'] as int?) ?? 0;
      final slug = m['slug']?.toString() ?? ''; final name = m['name']?.toString() ?? '';
      final thumb = m['thumb_url']?.toString() ?? ''; final quality = m['quality']?.toString() ?? '';
      final epName = m['ep_name']?.toString() ?? '';
      final episodeId = (m['episode_id'] as int?) ?? 0;
      final serverIdx = (m['server_idx'] as int?) ?? 0;
      final pos = (m['position'] as int?) ?? 0; final last = _timeAgo(m['last_watched']?.toString());
      return _glassTap(
        onTap: () => SmartlinkService.showSmartlinkBeforeAction(context, onDone: () => Navigator.push(context, MaterialPageRoute(builder: (_) => WatchScreen(
          movieId: movieId,
          episodeId: episodeId > 0 ? episodeId : 1,
          serverIdx: serverIdx,
          movieSlug: slug,
          movieTitle: name,
          initialPosition: pos,
        )))),
        child: Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppTheme.bgCard, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            ClipRRect(borderRadius: BorderRadius.circular(6),
              child: CachedNetworkImage(imageUrl: thumb, width: 56, height: 80, fit: BoxFit.cover,
                placeholder: (_, __) => Container(width: 56, height: 80, color: AppTheme.bgCard),
                errorWidget: (_, __, ___) => Container(width: 56, height: 80, color: AppTheme.bgCard, child: const Icon(Icons.movie, color: AppTheme.textMuted)))),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              if (quality.isNotEmpty) Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: AppTheme.accent, borderRadius: BorderRadius.circular(3)),
                child: Text(quality, style: const TextStyle(color: Color(0xFF1A1100), fontSize: 9, fontWeight: FontWeight.w700))),
              if (epName.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
                child: Text('Tiếp tục${epName.isNotEmpty ? ' — ${epName.toLowerCase().startsWith('tập') ? epName : 'Tập $epName'}' : ''}${pos > 0 ? ' · ${_fmtPos(pos)}' : ''}',
                    style: const TextStyle(color: AppTheme.accent, fontSize: 12, fontWeight: FontWeight.w500))),
              Padding(padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  const Icon(Icons.access_time_rounded, size: 11, color: AppTheme.textMuted),
                  const SizedBox(width: 3),
                  Expanded(child: Text(last, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11))),
                ])),
            ])),
            Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted, size: 20),
          ])),
      );
    }).toList());
  }

  Widget _buildComments() {
    if (_comments.isEmpty) return _emptyBox('Chưa có bình luận nào.');
    return Column(children: _comments.map((c) {
      final content = c['content']?.toString() ?? ''; final movieName = c['movie_name']?.toString() ?? '';
      final movieSlug = c['movie_slug']?.toString() ?? ''; final rating = c['rating'];
      final createdAt = _timeAgo(c['created_at']?.toString()); final status = c['status']?.toString() ?? '';
      String sLabel, sColor;
      switch (status) { case 'approved': sLabel = '✓ Hiển thị'; sColor = '#4caf50'; break;
        case 'pending': sLabel = '⏳ Chờ duyệt'; sColor = '#ff9800'; break;
        default: sLabel = '✕ Ẩn'; sColor = '#f44336'; break; }
      return Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppTheme.bgCard, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: _glassTap(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MovieDetailScreen(slug: movieSlug))),
              child: Row(children: [
                const Text('🎬 ', style: TextStyle(fontSize: 14)),
                Expanded(child: Text(movieName, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.accent, fontSize: 13, fontWeight: FontWeight.w600))),
              ]))),
            const SizedBox(width: 8),
            if (rating != null && rating.toString().isNotEmpty)
              Text('★ ${(rating is int ? rating : double.tryParse(rating.toString())?.toInt() ?? 0)}/10',
                  style: const TextStyle(color: Color(0xFFFFD700), fontSize: 11)),
            const SizedBox(width: 8),
            Text(createdAt, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            const SizedBox(width: 8),
            Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(color: Color(int.parse(sColor.replaceFirst('#', '0xFF')) | 0x22000000), borderRadius: BorderRadius.circular(4)),
              child: Text(sLabel, style: TextStyle(color: Color(int.parse(sColor.replaceFirst('#', '0xFF'))), fontSize: 9, fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 8),
          Text(content, style: const TextStyle(color: AppTheme.textSub, fontSize: 13, height: 1.5)),
        ]));
    }).toList());
  }

  Widget _buildSettings() {
    return _glassCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('⚙️ Cài Đặt Tài Khoản', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
      const SizedBox(height: 20),
      if (_successMsg != null) Container(width: double.infinity, padding: const EdgeInsets.all(10), margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
        child: Text(_successMsg!, style: const TextStyle(color: Colors.greenAccent, fontSize: 13))),
      _field('Tên đăng nhập', TextField(
        controller: TextEditingController(text: _profileData?['user']?['username']?.toString() ?? ''), enabled: false,
        style: const TextStyle(color: AppTheme.textMuted, fontSize: 14), decoration: _deco('', enabled: false))),
      const SizedBox(height: 14),
      _field('Email *', TextField(controller: _emailCtrl, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14), decoration: _deco('Nhập email'))),
      const SizedBox(height: 14),
      _field('URL Avatar', Row(children: [
        Expanded(child: TextField(controller: _avatarCtrl, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14), decoration: _deco('https://example.com/avatar.jpg'))),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () async {
            final picker = ImagePicker();
            final image = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
            if (image == null || !mounted) return;

            setState(() => _isSaving = true);
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đang upload...')));

            try {
              // 1. Upload ảnh
              final url = await ProfileService().uploadAvatar(File(image.path));
              if (url == null || !mounted) {
                setState(() => _isSaving = false);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Upload thất bại')));
                return;
              }

              // 2. Set URL (không cache bust cho DB)
              _avatarCtrl.text = url;

              // 3. Save profile với URL gốc
              await ProfileService().updateProfile(
                email: _emailCtrl.text.trim(),
                avatar: url,
              );

              if (!mounted) return;

              // 4. Cập nhật AuthProvider → BottomNav sync
              await context.read<AuthProvider>().updateAvatar(url);

              // 4. Cập nhật profileData local
              if (_profileData != null && _profileData!['user'] != null) {
                (_profileData!['user'] as Map<String, dynamic>)['avatar'] = url;
              }

              setState(() {});
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cập nhật avatar thành công!')));
            } catch (e) {
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lỗi kết nối')));
            } finally {
              if (mounted) setState(() => _isSaving = false);
            }
          },
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.accent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.accent.withOpacity(0.3)),
            ),
            child: Icon(Icons.add_photo_alternate_rounded, color: AppTheme.accent, size: 22),
          ),
        ),
      ])),
      const SizedBox(height: 20),
      _goldBtn(_isSaving ? null : _saveSettings, _isSaving ? 'Đang lưu...' : 'Lưu Thay Đổi', loading: _isSaving),
    ]));
  }

  Widget _buildSecurity() {
    return Column(children: [
      _glassCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('🔒 Đổi Mật Khẩu', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 20),
        if (_successMsg != null) Container(width: double.infinity, padding: const EdgeInsets.all(10), margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
          child: Text(_successMsg!, style: const TextStyle(color: Colors.greenAccent, fontSize: 13))),
        _field('Mật khẩu hiện tại *', TextField(controller: _oldPassCtrl, obscureText: true,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14), decoration: _deco('Nhập mật khẩu hiện tại'))),
        const SizedBox(height: 14),
        _field('Mật khẩu mới *', TextField(controller: _newPassCtrl, obscureText: true,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14), decoration: _deco('Ít nhất 6 ký tự'))),
        const SizedBox(height: 14),
        _field('Xác nhận mật khẩu mới *', TextField(controller: _confirmPassCtrl, obscureText: true,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14), decoration: _deco('Nhập lại mật khẩu mới'))),
        const SizedBox(height: 20),
        _goldBtn(_isSaving ? null : _changePassword, _isSaving ? 'Đang xử lý...' : 'Đổi Mật Khẩu', loading: _isSaving),
      ])),
      const SizedBox(height: 20),
      _glassCard(borderColor: Colors.redAccent.withValues(alpha: 0.25), bgColor: Colors.redAccent.withValues(alpha: 0.03),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('⚠️ Vùng nguy hiểm', style: TextStyle(color: Colors.redAccent, fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Đăng xuất khỏi tất cả thiết bị và xoá session hiện tại.', style: TextStyle(color: AppTheme.textSub, fontSize: 12)),
          const SizedBox(height: 12),
          _glassBtnRow(onTap: () => _confirmLogoutAll(), child: Container(padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
            decoration: BoxDecoration(border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)), borderRadius: BorderRadius.circular(8),
              color: Colors.redAccent.withValues(alpha: 0.08)),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.logout_rounded, size: 14, color: Colors.redAccent), SizedBox(width: 6),
              Text('Đăng xuất ngay', style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600)),
            ]))),
        ])),
    ]);
  }

  // ── About section ──
  Widget _buildAboutSection() {
    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                'assets/images/logo.png',
                width: 40, height: 40,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Xiao Phim', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w800)),
                  Text('Xem phim online', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 16),
          _aboutRow(Icons.info_outline_rounded, 'Phiên bản', _appVersion.isNotEmpty ? _appVersion : '...'),
          const SizedBox(height: 10),
          _aboutRow(Icons.language_rounded, 'Website', 'xiaofilm.online'),
          const SizedBox(height: 10),
          _aboutRow(Icons.movie_filter_rounded, 'Nội dung', 'Phim bộ, phim lẻ, anime'),
          const SizedBox(height: 10),
          _aboutRow(Icons.devices_rounded, 'Nền tảng', 'iOS & Android'),
          const SizedBox(height: 16),
          const Divider(color: AppTheme.border, height: 1),
          const SizedBox(height: 12),
          const Text(
            'Ứng dụng được phát triển với mục đích giải trí. '
            'Nội dung được tổng hợp từ nhiều nguồn khác nhau.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _aboutRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppTheme.textMuted),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: AppTheme.textSub, fontSize: 13)),
        const Spacer(),
        Text(value, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  // ── Btn back ──
  Widget _glassBtn(VoidCallback? onTap, {required Widget child}) {
    return _glassTap(onTap: onTap, child: child);
  }
  Widget _glassBtnRow({VoidCallback? onTap, required Widget child}) {
    return _glassTap(onTap: onTap, child: Container(
      width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: AppTheme.bgCard, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(14)),
      child: child,
    ));
  }

  Widget _glassCard({required Widget child, Color? borderColor, Color? bgColor}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: bgColor ?? AppTheme.bgCard,
        border: Border.all(color: borderColor ?? AppTheme.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  Widget _glassTap({VoidCallback? onTap, required Widget child}) {
    if (onTap == null) return child;
    return GestureDetector(
      onTap: onTap,
      child: _PressScale(child: child),
    );
  }

  Widget _goldBtn(VoidCallback? onTap, String label, {bool loading = false}) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: _PressScale(
        child: Container(padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 28),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFFFFE59A), Color(0xFFF5C84C)]),
            borderRadius: BorderRadius.circular(999),
            boxShadow: onTap != null
                ? [BoxShadow(color: AppTheme.accent.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 6))]
                : null,
          ),
          child: loading
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1A1100)))
              : Text(label, style: const TextStyle(color: Color(0xFF1A1100), fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
        ),
      ),
    );
  }

  Widget _buildLogoutBtn() {
    return _glassTap(
      onTap: _confirmLogout,
      child: Container(
        width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.logout_rounded, size: 18, color: Colors.redAccent),
          SizedBox(width: 8),
          Text('Đăng Xuất', style: TextStyle(color: Colors.redAccent, fontSize: 15, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  Future<void> _saveSettings() async {
    setState(() { _isSaving = true; _successMsg = null; });
    try {
      final res = await _profileService.updateProfile(email: _emailCtrl.text.trim(), avatar: _avatarCtrl.text.trim());
      if (!mounted) return;
      if (res['success'] == true) setState(() => _successMsg = res['message']?.toString() ?? 'Cập nhật thành công!');
      else _showErr(res['error']?.toString() ?? 'Lỗi cập nhật');
    } catch (_) { if (mounted) _showErr('Lỗi kết nối'); }
    if (mounted) setState(() => _isSaving = false);
  }

  Future<void> _changePassword() async {
    if (_oldPassCtrl.text.isEmpty || _newPassCtrl.text.isEmpty || _confirmPassCtrl.text.isEmpty)
      { _showErr('Vui lòng nhập đầy đủ thông tin'); return; }
    if (_newPassCtrl.text.length < 6) { _showErr('Mật khẩu mới phải ít nhất 6 ký tự'); return; }
    if (_newPassCtrl.text != _confirmPassCtrl.text) { _showErr('Mật khẩu xác nhận không khớp'); return; }
    setState(() { _isSaving = true; _successMsg = null; });
    try {
      final res = await _profileService.changePassword(oldPassword: _oldPassCtrl.text, newPassword: _newPassCtrl.text);
      if (!mounted) return;
      if (res['success'] == true) {
        _oldPassCtrl.clear(); _newPassCtrl.clear(); _confirmPassCtrl.clear();
        setState(() => _successMsg = res['message']?.toString() ?? 'Đổi mật khẩu thành công!');
      } else _showErr(res['error']?.toString() ?? 'Lỗi đổi mật khẩu');
    } catch (_) { if (mounted) _showErr('Lỗi kết nối'); }
    if (mounted) setState(() => _isSaving = false);
  }

  void _showErr(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('⚠️ $m'), backgroundColor: Colors.redAccent, duration: const Duration(seconds: 3)));

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      backgroundColor: AppTheme.bgCard,
      title: const Text('Đăng xuất?', style: TextStyle(color: AppTheme.textPrimary)),
      content: const Text('Bạn có chắc muốn đăng xuất không?', style: TextStyle(color: AppTheme.textSub)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Hủy', style: TextStyle(color: AppTheme.textSub))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Đăng xuất', style: TextStyle(color: Colors.redAccent))),
      ],
    ));
    if (ok == true && mounted) context.read<AuthProvider>().logout();
  }

  Future<void> _confirmLogoutAll() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      backgroundColor: AppTheme.bgCard,
      title: const Text('Đăng xuất?', style: TextStyle(color: AppTheme.textPrimary)),
      content: const Text('Đăng xuất khỏi tất cả thiết bị?', style: TextStyle(color: AppTheme.textSub)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Hủy', style: TextStyle(color: AppTheme.textSub))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Đăng xuất', style: TextStyle(color: Colors.redAccent))),
      ],
    ));
    if (ok == true && mounted) context.read<AuthProvider>().logout();
  }

  Widget _avatarFallback(String i) => Container(
    decoration: const BoxDecoration(gradient: LinearGradient(colors: [AppTheme.accent, Color(0xFFFF6B35)])),
    child: Center(child: Text(i, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800))));

  Widget _statItem(IconData icon, String label, String value) => Expanded(child: Column(children: [
    Icon(icon, size: 18, color: AppTheme.accent), const SizedBox(height: 4),
    Text(value, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w800)),
    const SizedBox(height: 1),
    Text(label, style: const TextStyle(color: AppTheme.textSub, fontSize: 10)),
  ]));
  Widget _vDiv() => Container(width: 1, height: 32, color: AppTheme.border);
  Widget _field(String l, Widget w) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(l, style: const TextStyle(color: AppTheme.textSub, fontSize: 12)), const SizedBox(height: 6), w]);
  InputDecoration _deco(String hint, {bool enabled = true}) => InputDecoration(
    hintText: hint, filled: true, fillColor: enabled ? AppTheme.bgSurface : AppTheme.bgCard,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.border)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.border)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.gold)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12));
}

class _TabDef { final String label, tab; final IconData icon; _TabDef(this.label, this.icon, this.tab); }

// ── Press scale animation (liquid glass hover) ──
class _PressScale extends StatefulWidget {
  final Widget child;
  const _PressScale({required this.child});

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _ctrl.forward(),
      onPointerUp: (_) => _ctrl.reverse(),
      onPointerCancel: (_) => _ctrl.reverse(),
      child: AnimatedBuilder(
        animation: _anim,
        builder: (_, child) => Transform.scale(scale: 1.0 - _anim.value * 0.04, child: child),
        child: widget.child,
      ),
    );
  }
}
