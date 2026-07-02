import 'package:flutter/material.dart';

class Responsive {
  static bool isMobile(BuildContext context) => MediaQuery.of(context).size.width < 600;
  static bool isTablet(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return w >= 600 && w < 900;
  }
  static bool isDesktop(BuildContext context) => MediaQuery.of(context).size.width >= 900;
  static bool isLandscape(BuildContext context) => MediaQuery.of(context).orientation == Orientation.landscape;

  static double width(BuildContext context) => MediaQuery.of(context).size.width;
  static double height(BuildContext context) => MediaQuery.of(context).size.height;

  static int gridColumns(BuildContext context) {
    final w = width(context);
    if (w >= 1200) return 6;
    if (w >= 900) return 5;
    if (w >= 600) return 4;
    return 3;
  }

  static int episodeColumns(BuildContext context) {
    final w = width(context);
    if (w >= 1200) return 8;
    if (w >= 900) return 6;
    if (w >= 600) return 5;
    return 4;
  }

  static double maxContentWidth(BuildContext context) {
    final w = width(context);
    if (w >= 900) return 900;
    return w;
  }

  static Widget constrained(BuildContext context, {required Widget child}) {
    if (!isDesktop(context) && !isTablet(context)) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxContentWidth(context)),
        child: child,
      ),
    );
  }
}
