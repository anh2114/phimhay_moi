import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:url_launcher/url_launcher.dart';

class BottomNav extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTabSelected;
  final String? avatarUrl;

  const BottomNav({
    super.key,
    required this.currentIndex,
    required this.onTabSelected,
    this.avatarUrl,
  });

  @override
  State<BottomNav> createState() => _BottomNavState();
}

class _BottomNavState extends State<BottomNav> {
  static const _tabs = [
    _TabItem(Icons.home_rounded, 'Trang chủ'),
    _TabItem(Icons.search_rounded, 'Tìm kiếm'),
    _TabItem(Icons.calendar_month_outlined, 'Lịch chiếu'),
    _TabItem(Icons.person_outline, 'Tài khoản'),
  ];

  static const _telegramUrl = 'https://t.me/xiaophimc';
  static const _discordUrl = 'https://discord.gg/77aBStuUXg';

  final GlobalKey _groupBtnKey = GlobalKey();

  void _showCommunityPopup() {
    final ctx = _groupBtnKey.currentContext;
    if (ctx == null) return;
    final RenderBox? button = ctx.findRenderObject() as RenderBox?;
    final RenderBox? overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null) return;

    final buttonPos = button.localToGlobal(Offset.zero, ancestor: overlay);
    final buttonSize = button.size;

    showMenu(
      context: context,
      color: const Color(0xFF1E2026),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      position: RelativeRect.fromLTRB(
        buttonPos.dx - 40,
        buttonPos.dy - 140,
        buttonPos.dx + buttonSize.width + 40,
        buttonPos.dy - 10,
      ),
      items: [
        PopupMenuItem(
          height: 44,
          onTap: () => launchUrl(Uri.parse(_telegramUrl), mode: LaunchMode.externalApplication),
          child: Row(
            children: [
              SvgPicture.asset(
                'assets/svg_ui_controls/telegram-icon.svg',
                width: 20, height: 20,
                colorFilter: const ColorFilter.mode(Color(0xFF0088CC), BlendMode.srcIn),
              ),
              const SizedBox(width: 10),
              const Text('Telegram', style: TextStyle(color: Colors.white, fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem(
          height: 44,
          onTap: () => launchUrl(Uri.parse(_discordUrl), mode: LaunchMode.externalApplication),
          child: Row(
            children: [
              SvgPicture.asset(
                'assets/svg_ui_controls/discord-icon-svgrepo-com.svg',
                width: 20, height: 20,
                colorFilter: const ColorFilter.mode(Color(0xFF5865F2), BlendMode.srcIn),
              ),
              const SizedBox(width: 10),
              const Text('Discord', style: TextStyle(color: Colors.white, fontSize: 14)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final isTablet = screenW >= 600;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 6, right: 6),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isTablet ? 420 : double.infinity),
          child: GlassBottomBar(
        barHeight: 60,
        iconSize: 24,
        spacing: 8,
        horizontalPadding: 16,
        verticalPadding: 14,
        indicatorPinchStrength: 0.2,
        glowBlurRadius: 24,
        glowSpreadRadius: 6,
        glowOpacity: 0.5,
        glowDuration: Duration(milliseconds: 250),
        selectedIndex: widget.currentIndex,
        onTabSelected: widget.onTabSelected,
        tabs: List.generate(_tabs.length, (i) {
          final tab = _tabs[i];
          return GlassBottomBarTab(
            icon: (i == 3 && widget.avatarUrl != null && widget.avatarUrl!.isNotEmpty)
                ? ClipOval(
                    child: CachedNetworkImage(
                      imageUrl: widget.avatarUrl!,
                      width: 26, height: 26, fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Icon(
                        tab.icon,
                        color: i == widget.currentIndex ? AppTheme.accent : Colors.white,
                        size: 22,
                      ),
                    ),
                  )
                : Icon(
                    tab.icon,
                    color: i == widget.currentIndex ? AppTheme.accent : Colors.white,
                    size: 22,
                  ),
          );
        }),
        extraButton: GlassBottomBarExtraButton(
          icon: KeyedSubtree(
            key: _groupBtnKey,
            child: const Icon(Icons.groups_rounded, color: Colors.white, size: 24),
          ),
          label: 'Community',
          iconColor: Colors.white,
          size: 58,
          onTap: _showCommunityPopup,
        ),
      ),
        ),
      ),
    );
  }
}

class _TabItem {
  final IconData icon;
  final String label;
  const _TabItem(this.icon, this.label);
}
