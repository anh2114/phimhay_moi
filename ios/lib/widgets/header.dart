import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:phimhay_app/config/app_config.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:provider/provider.dart';
import 'package:phimhay_app/providers/auth_provider.dart';
import 'package:phimhay_app/services/image_cache_manager.dart';

class Header extends StatefulWidget {
  final VoidCallback? onSearchTap;
  final VoidCallback? onNotificationTap;
  final VoidCallback? onAccountTap;
  final VoidCallback? onWatchPartyTap;
  final VoidCallback? onActorsTap;
  final double backgroundOpacity;

  const Header({
    super.key,
    this.onSearchTap,
    this.onNotificationTap,
    this.onAccountTap,
    this.onWatchPartyTap,
    this.onActorsTap,
    this.backgroundOpacity = 1.0,
  });

  @override
  State<Header> createState() => _HeaderState();
}

class _HeaderState extends State<Header> {
  double _topPadding = 0;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _topPadding = MediaQuery.of(context).padding.top;
  }

  void _togglePopup() {
    if (_overlayEntry != null) {
      _closePopup();
    } else {
      _showPopup();
    }
  }

  void _showPopup() {
    _overlayEntry = OverlayEntry(
      builder: (ctx) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _closePopup,
        child: Stack(
          children: [
            // Full screen tap to dismiss
            Positioned.fill(child: Container(color: Colors.transparent)),
            // Menu popup
            Positioned(
              top: MediaQuery.of(context).padding.top + 56,
              right: 16,
              width: 220,
              child: GestureDetector(
                onTap: () {}, // Ngăn tap qua menu
                child: Material(
                  color: Colors.transparent,
                  child: _PopupMenu(
                    onClose: _closePopup,
                    onSearch: () { _closePopup(); widget.onSearchTap?.call(); },
                    onWatchParty: () { _closePopup(); widget.onWatchPartyTap?.call(); },
                    onNotifications: () { _closePopup(); widget.onNotificationTap?.call(); },
                    onActors: () { _closePopup(); widget.onActorsTap?.call(); },
                    onAccount: () { _closePopup(); widget.onAccountTap?.call(); },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _closePopup() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.user;
    final rawAvatar = user?['avatar']?.toString() ?? '';
    final avatarUrl = rawAvatar.isNotEmpty && !rawAvatar.startsWith('http') ? '${AppConfig.baseUrl}$rawAvatar' : rawAvatar;
    final isLoggedIn = auth.isLoggedIn;
    final username = user?['username']?.toString() ?? '';
    final initial = username.isNotEmpty ? username[0].toUpperCase() : '';
    final opacity = widget.backgroundOpacity;

    Widget child = Container(
      padding: EdgeInsets.only(top: _topPadding),
      decoration: opacity < 0.01
          ? null
          : BoxDecoration(
              color: Color.fromRGBO(13, 15, 20, opacity),
              border: Border(bottom: BorderSide(color: Color.fromRGBO(255, 255, 255, 0.1 * opacity), width: 0.5)),
            ),
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              GestureDetector(
                child: Image.asset(
                  'assets/images/logo2.png',
                  height: 28,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Text('Xiao Phim', style: TextStyle(color: AppTheme.gold, fontSize: 22, fontWeight: FontWeight.bold)),
                ),
              ),
              const Spacer(),
              CompositedTransformTarget(
                link: _layerLink,
                child: GestureDetector(
                  onTap: _togglePopup,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: isLoggedIn && avatarUrl.isNotEmpty
                        ? Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: AppTheme.accent, width: 1.5),
                            ),
                            child: ClipOval(
                              child: CachedNetworkImage(
                                imageUrl: avatarUrl,
                                fit: BoxFit.cover,
                                cacheManager: AppImageCacheManager(),
                                fadeInDuration: Duration.zero,
                                placeholder: (_, __) => _avatarFallback(initial),
                                errorWidget: (_, __, ___) => _avatarFallback(initial),
                              ),
                            ),
                          )
                        : isLoggedIn
                            ? Container(
                                width: 32,
                                height: 32,
                                decoration: const BoxDecoration(shape: BoxShape.circle, color: AppTheme.accent),
                                child: Center(
                                  child: Text(initial, style: const TextStyle(color: Color(0xFF1A1100), fontSize: 14, fontWeight: FontWeight.w800)),
                                ),
                              )
                            : Icon(Icons.person_outline, color: AppTheme.textPrimary, size: 22),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (opacity > 0.1) {
      child = ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10 * opacity, sigmaY: 10 * opacity),
          child: child,
        ),
      );
    }

    return child;
  }

  Widget _avatarFallback(String initial) {
    return Container(
      color: AppTheme.accent,
      child: Center(
        child: Text(initial, style: const TextStyle(color: Color(0xFF1A1100), fontSize: 13, fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class _PopupMenu extends StatelessWidget {
  final VoidCallback onClose;
  final VoidCallback onSearch;
  final VoidCallback onWatchParty;
  final VoidCallback onNotifications;
  final VoidCallback onActors;
  final VoidCallback onAccount;

  const _PopupMenu({
    required this.onClose,
    required this.onSearch,
    required this.onWatchParty,
    required this.onNotifications,
    required this.onActors,
    required this.onAccount,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onClose,
      child: Container(
        width: 220,
        margin: const EdgeInsets.only(left: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1E26),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x33FFFFFF)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 20, offset: const Offset(0, 8))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PopupItem(icon: Icons.search_rounded, label: 'Tìm kiếm', onTap: onSearch),
            _PopupItem(icon: Icons.people_outline_rounded, label: 'Xem chung', onTap: onWatchParty),
            _PopupItem(icon: Icons.notifications_outlined, label: 'Thông báo', onTap: onNotifications),
            _PopupItem(icon: Icons.person_search_rounded, label: 'Diễn viên', onTap: onActors),
            const Divider(color: Color(0x22FFFFFF), height: 1, indent: 16, endIndent: 16),
            _PopupItem(icon: Icons.person_outline_rounded, label: 'Tài khoản', onTap: onAccount),
          ],
        ),
      ),
    );
  }
}

class _PopupItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PopupItem({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: AppTheme.textSub, size: 20),
              const SizedBox(width: 12),
              Text(label, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}
