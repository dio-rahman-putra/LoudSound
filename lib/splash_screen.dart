import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'main.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  late final AnimationController _fadeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..forward();

  Timer? _navigationTimer;

  @override
  void initState() {
    super.initState();
    // Berpindah ke Dashboard setelah animasi splash screen selesai (~2.4 detik)
    _navigationTimer =
        Timer(const Duration(milliseconds: 2400), _navigateToHome);
  }

  void _navigateToHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 650),
        pageBuilder: (context, animation, secondaryAnimation) =>
            const SoundDashboardPage(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
            ),
            child: child,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _navigationTimer?.cancel();
    _pulseController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // Ambient Glow Halus di Tengah Layar
          Center(
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.quiet.withValues(alpha: 0.14),
                    AppColors.normal.withValues(alpha: 0.04),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
            ),
          ),

          // Konten Utama Splash Screen
          Center(
            child: FadeTransition(
              opacity: _fadeController,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo dengan Animasi Gelombang Akustik Melingkar
                  SizedBox(
                    width: 170,
                    height: 170,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Gelombang Akustik Berdenyut (Concentric Sound Waves)
                        AnimatedBuilder(
                          animation: _pulseController,
                          builder: (context, _) {
                            return CustomPaint(
                              size: const Size(170, 170),
                              painter: _AcousticWavePainter(
                                progress: _pulseController.value,
                              ),
                            );
                          },
                        ),

                        // Logo Gambar LoudSound
                        const LoudSoundAppLogo(size: 110),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Wordmark Branding 'loudsound'
                  const Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'loud',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.8,
                          ),
                        ),
                        TextSpan(
                          text: 'sound',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w300,
                            letterSpacing: -0.8,
                          ),
                        ),
                      ],
                    ),
                    style: TextStyle(fontSize: 28),
                  ),
                  const SizedBox(height: 8),

                  // Tagline Minimalis
                  const Text(
                    'IOT ACOUSTIC & NOISE MONITOR',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 2.2,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Footer Status Loading di Bagian Bawah
          Positioned(
            bottom: 36,
            left: 0,
            right: 0,
            child: FadeTransition(
              opacity: _fadeController,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        AppColors.textMuted,
                      ),
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Memuat sistem akustik…',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Komponen Logo LoudSound dengan fallback otomatis agar tidak pernah error 404
class LoudSoundAppLogo extends StatelessWidget {
  const LoudSoundAppLogo({super.key, this.size = 110});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF090A0D),
        border: Border.all(
          color: AppColors.quiet.withValues(alpha: 0.4),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.quiet.withValues(alpha: 0.28),
            blurRadius: 26,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipOval(
        child: kIsWeb
            ? Image.network(
                'icons/Icon-512.png',
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    _loadAssetWithFallback(),
              )
            : _loadAssetWithFallback(),
      ),
    );
  }

  Widget _loadAssetWithFallback() {
    return Image.asset(
      'assets/logo/loudsound_logo.png',
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        return Image.asset(
          'assets/logo/loudsound_logo.jpg',
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return const LoudSoundVectorLogo();
          },
        );
      },
    );
  }
}

/// Logo vector kustom kualitas tinggi (CustomPainter) sebagai jaminan selalu tampil sempurna
class LoudSoundVectorLogo extends StatelessWidget {
  const LoudSoundVectorLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _LoudSoundVectorPainter(),
    );
  }
}

class _LoudSoundVectorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Background lingkaran gelap pekat
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = const Color(0xFF08090C),
    );

    // Cincin konsentris neon
    final ringColors = [
      AppColors.quiet,
      AppColors.normal,
      AppColors.quiet,
      AppColors.normal,
      AppColors.quiet,
    ];

    for (int i = 0; i < ringColors.length; i++) {
      final ringRadius = radius * (0.28 + (i * 0.14));
      final paint = Paint()
        ..color = ringColors[i].withValues(alpha: 0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(center, ringRadius, paint);
    }

    // Gelombang frekuensi suara akustik melintang di tengah
    final wavePath = Path();
    final w = size.width;
    final h = size.height;
    final cy = h / 2;

    wavePath.moveTo(0, cy);
    wavePath.lineTo(w * 0.22, cy);
    wavePath.cubicTo(w * 0.28, cy - h * 0.16, w * 0.32, cy - h * 0.16, w * 0.38, cy + h * 0.24);
    wavePath.cubicTo(w * 0.44, cy + h * 0.28, w * 0.48, cy - h * 0.05, w * 0.54, cy - h * 0.08);
    wavePath.cubicTo(w * 0.60, cy - h * 0.30, w * 0.68, cy - h * 0.32, w * 0.74, cy + h * 0.16);
    wavePath.cubicTo(w * 0.78, cy + h * 0.18, w * 0.82, cy, w * 0.88, cy);
    wavePath.lineTo(w, cy);

    // Efek pendaran gelombang
    final glowPaint = Paint()
      ..color = AppColors.quiet.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
    canvas.drawPath(wavePath, glowPaint);

    final linePaint = Paint()
      ..shader = const LinearGradient(
        colors: [AppColors.quiet, AppColors.normal, AppColors.quiet],
      ).createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(wavePath, linePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Painter untuk efek lingkaran gelombang suara akustik
class _AcousticWavePainter extends CustomPainter {
  const _AcousticWavePainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    for (int i = 0; i < 2; i++) {
      final ringProgress = (progress + (i * 0.5)) % 1.0;
      final radius = 54.0 + (ringProgress * 28.0);
      final opacity = math.sin(ringProgress * math.pi) * 0.45;

      final paint = Paint()
        ..color = AppColors.quiet.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;

      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _AcousticWavePainter oldDelegate) =>
      oldDelegate.progress != progress;
}
