import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:url_launcher/url_launcher.dart';

class BottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTabSelected;
  final String? avatarUrl;

  const BottomNav({
    super.key,
    required this.currentIndex,
    required this.onTabSelected,
    this.avatarUrl,
  });

  static const _tabs = [
    _TabItem(Icons.home_rounded, 'Trang chủ'),
    _TabItem(Icons.search_rounded, 'Tìm kiếm'),
    _TabItem(Icons.calendar_month_outlined, 'Lịch chiếu'),
    _TabItem(Icons.person_outline, 'Tài khoản'),
  ];

  static const _telegramUrl = 'https://t.me/xiaophimc';
  static const _discordUrl = 'https://discord.gg/77aBStuUXg';

  void _showCommunityPopup(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;

    showMenu(
      context: context,
      color: const Color(0xFF1E2026),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      position: RelativeRect.fromRect(
        Rect.fromCenter(
          center: renderBox != null
              ? renderBox.localToGlobal(
                  Offset(renderBox.size.width / 2, -60),
                  ancestor: overlay,
                )
              : Offset.zero,
          width: 160,
          height: 0,
        ),
        Offset.zero & (overlay?.size ?? Size.zero),
      ),
      items: [
        PopupMenuItem(
          height: 44,
          onTap: () => launchUrl(Uri.parse(_telegramUrl), mode: LaunchMode.externalApplication),
          child: Row(
            children: [
              SvgPicture.asset(
                'assets/svg_ui_controls/telegram-icon.svg',
                width: 20,
                height: 20,
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
                width: 20,
                height: 20,
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 10, right: 10),
      child: GlassBottomBar(
        selectedIndex: currentIndex,
        onTabSelected: onTabSelected,
        tabs: List.generate(_tabs.length, (i) {
          final tab = _tabs[i];
          return GlassBottomBarTab(
            icon: (i == 3 && avatarUrl != null && avatarUrl!.isNotEmpty)
                ? ClipOval(
                    child: CachedNetworkImage(
                      imageUrl: avatarUrl!,
                      width: 32,
                      height: 32,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Icon(
                        tab.icon,
                        color: i == currentIndex
                            ? AppTheme.accent
                            : Colors.white,
                        size: 30,
                      ),
                    ),
                  )
                : Icon(
                    tab.icon,
                    color: i == currentIndex
                        ? AppTheme.accent
                        : Colors.white,
                    size: 30,
                  ),
          );
        }),
        extraButton: GlassBottomBarExtraButton(
          icon: const Icon(Icons.groups_rounded, color: Colors.white, size: 28),
          label: 'Community',
          iconColor: Colors.white,
          size: 64,
          onTap: () => _showCommunityPopup(context),
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
