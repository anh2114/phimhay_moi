import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/theme.dart';
import '../../services/update_service.dart';
import '../../widgets/update_dialog.dart';

class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeIn;
  late Animation<double> _scale;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
    _fadeIn = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.85, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    _controller.forward();

    // Dismiss splash + check update
    Future.delayed(const Duration(milliseconds: 2500), () async {
      if (mounted) setState(() => _ready = true);

      // Check update sau khi splash xong
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        try {
          final updateInfo = await UpdateService().checkUpdate();
          if (updateInfo.hasUpdate && mounted) {
            await UpdateDialog.show(context, updateInfo);
          }
        } catch (_) {}
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Main content — visible after splash
        AnimatedOpacity(
          opacity: _ready ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 400),
          child: widget.child,
        ),
        // Splash overlay
        if (!_ready)
          Container(
            color: AppTheme.bg,
            child: FadeTransition(
              opacity: _fadeIn,
              child: ScaleTransition(
                scale: _scale,
                child: SizedBox(
                  width: double.infinity,
                  height: double.infinity,
                  child: Stack(
                    children: [
                      // Logo — center
                      Center(
                        child: Image.asset(
                          'assets/images/logo2.png',
                          width: 180,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Text(
                            'Xiao Phim',
                            style: GoogleFonts.inter(
                              fontSize: 36,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.gold,
                              letterSpacing: -1,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                      // Spinner + "Đang tải" — bottom 20%
                      Positioned(
                        bottom: MediaQuery.of(context).size.height * 0.2,
                        left: 0,
                        right: 0,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 32,
                              height: 32,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            ),
                            const SizedBox(height: 12),
                            DecoratedBox(
                              decoration: const BoxDecoration(),
                              child: Text(
                                'Đang tải',
                                style: GoogleFonts.inter(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
