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
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 10, right: 10),
      child: GlassBottomBar(
        barHeight: 54,
        iconSize: 22,
        spacing: 6,
        horizontalPadding: 12,
        verticalPadding: 12,
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
            child: const Icon(Icons.groups_rounded, color: Colors.white, size: 22),
          ),
          label: 'Community',
          iconColor: Colors.white,
          size: 48,
          onTap: _showCommunityPopup,
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
