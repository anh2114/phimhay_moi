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
          icon: SizedBox(
            width: 28,
            height: 28,
            child: SvgPicture.asset(
              'assets/svg_ui_controls/telegram-icon.svg',
              width: 28,
              height: 28,
              colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
            ),
          ),
          label: 'Telegram',
          iconColor: Colors.white,
          size: 64,
          onTap: () => launchUrl(Uri.parse(_telegramUrl), mode: LaunchMode.externalApplication),
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
