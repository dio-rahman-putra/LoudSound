import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';

enum SoundUnit { db, rms }

enum HeroStatus { offline, waiting, live, stale }

class SoundReading {
  const SoundReading(this.db, this.rms);

  final double db;
  final double rms;

  double valueFor(SoundUnit unit) => unit == SoundUnit.db ? db : rms;
}

({String value, String unit}) formatValue(
  double v,
  SoundUnit unit,
) {
  if (unit == SoundUnit.db) {
    return (value: v.toStringAsFixed(1), unit: 'dB');
  }
  // RMS = tekanan suara terkalibrasi (Pascal) yang diturunkan dari dB SPL:
  // p = 20 µPa × 10^(dB/20)  ->  94 dB SPL = 1 Pa.
  if (v >= 1.0) {
    return (value: v.toStringAsFixed(2), unit: 'Pa');
  }
  return (value: (v * 1000).toStringAsFixed(v >= 0.01 ? 1 : 2), unit: 'mPa');
}

/// Bagian utama: angka di tengah layar dengan sorotan cahaya halus (spotlight),
/// tanpa menggunakan card sehingga menyatu alami dengan latar belakang.
class HeroReading extends StatelessWidget {
  const HeroReading({
    super.key,
    required this.db,
    required this.rms,
    required this.unit,
    required this.onUnitChanged,
    required this.status,
    this.iotStatus,
  });

  final double? db;
  final double? rms;
  final SoundUnit unit;
  final ValueChanged<SoundUnit> onUnitChanged;
  final HeroStatus status;
  final String? iotStatus;

  @override
  Widget build(BuildContext context) {
    final dbValue = db;
    final rmsValue = rms;
    final hasData = dbValue != null && rmsValue != null;
    final isIotLoud = iotStatus == 'TERLALU BERISIK';
    final baseLevel = dbValue == null ? null : NoiseLevel.fromDb(dbValue);
    final level = isIotLoud ? NoiseLevel.loud : baseLevel;
    final accent = isIotLoud
        ? AppColors.loud
        : (level?.color ?? AppColors.textMuted);
    final value = hasData ? (unit == SoundUnit.db ? dbValue : rmsValue) : null;

    final String title;
    final String description;
    switch (status) {
      case HeroStatus.offline:
        title = 'IoT Belum Terhubung';
        description = 'Hubungkan perangkat Noise_Monitor untuk mulai membaca.';
      case HeroStatus.waiting:
        title = 'Menunggu Data';
        description = 'Perangkat ter-pair, menyinkronkan data I2S sensor…';
      case HeroStatus.live:
      case HeroStatus.stale:
        if (isIotLoud) {
          title = 'TERLALU BERISIK · ALARM IOT';
          description = 'Buzzer ESP32 aktif! Suara melewati ambang batas aman.';
        } else {
          title = '${level?.label.toUpperCase()} · ${level?.range}';
          description = level?.description ?? '';
        }
    }

    // Sorotan radial ambient di belakang angka
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(
        end: hasData
            ? accent.withValues(alpha: 0.18)
            : const Color(0xFF222834).withValues(alpha: 0.12),
      ),
      duration: const Duration(milliseconds: 700),
      builder: (context, glowColor, child) {
        final color = glowColor ?? Colors.transparent;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 0.75,
              colors: [
                color,
                color.withValues(alpha: 0.04),
                Colors.transparent,
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
          child: child,
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. Pemilih Satuan dB / RMS (Pill Switch Minimalis tanpa card kotak)
            UnitSelectorPill(unit: unit, onChanged: onUnitChanged),
            const SizedBox(height: 26),

            // 2. Angka Utama (Tersorot di Tengah Layar)
            _AnimatedReading(value: value, unit: unit),
            const SizedBox(height: 6),

            // 3. Label Satuan yang Elegan
            Text(
              value == null
                  ? (unit == SoundUnit.db ? 'DECIBEL' : 'RMS')
                  : (unit == SoundUnit.db
                      ? 'DECIBEL (dB SPL)'
                      : 'TEKANAN SUARA · RMS (${formatValue(value, unit).unit})'),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.4,
              ),
            ),
            const SizedBox(height: 22),

            // 4. Status Akustik / Kondisi Sensor
            AnimatedContainer(
              duration: const Duration(milliseconds: 350),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: hasData
                    ? accent.withValues(alpha: 0.12)
                    : AppColors.surfaceRaised.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: hasData
                      ? accent.withValues(alpha: 0.3)
                      : AppColors.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                      boxShadow: level == null
                          ? null
                          : [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.6),
                                blurRadius: 8,
                              ),
                            ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: TextStyle(
                      color: hasData ? accent : AppColors.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // 5. Penjelasan Singkat
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                description,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 14),

            // 6. Indikator Realtime
            _LiveIndicator(status: status),
          ],
        ),
      ),
    );
  }
}

class _AnimatedReading extends StatelessWidget {
  const _AnimatedReading({required this.value, required this.unit});

  final double? value;
  final SoundUnit unit;

  static const double _size = 118;

  @override
  Widget build(BuildContext context) {
    final target = value;
    if (target == null) {
      return Text(
        '--',
        style: AppText.number(
          _size,
          color: AppColors.textMuted.withValues(alpha: 0.4),
          weight: FontWeight.w200,
        ),
      );
    }

    // Tanpa TweenAnimationBuilder: angka langsung berubah mengikuti data
    // sehingga tidak menambah delay tampilan.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        formatValue(target, unit).value,
        style: AppText.number(_size, weight: FontWeight.w200),
      ),
    );
  }
}

class _LiveIndicator extends StatefulWidget {
  const _LiveIndicator({required this.status});

  final HeroStatus status;

  @override
  State<_LiveIndicator> createState() => _LiveIndicatorState();
}

class _LiveIndicatorState extends State<_LiveIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final isPaired = status == HeroStatus.live ||
        status == HeroStatus.stale ||
        status == HeroStatus.waiting;
    final stale = status == HeroStatus.stale;
    final color = stale
        ? AppColors.normal
        : (isPaired ? AppColors.quiet : AppColors.textMuted);

    final String label;
    if (status == HeroStatus.offline) {
      label = 'OFFLINE · DEVICE BELUM KE-PAIR';
    } else if (status == HeroStatus.waiting) {
      label = 'TERHUBUNG · MENYINKRONKAN DATA';
    } else if (status == HeroStatus.stale) {
      label = 'DATA TERTUNDA · MENUNGGU SAMBUNGAN IOT';
    } else {
      label = 'LIVE · REALTIME';
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isPaired)
          FadeTransition(
            opacity: Tween<double>(begin: 0.35, end: 1.0).animate(_pulse),
            child: Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.7),
                    blurRadius: 7,
                  ),
                ],
              ),
            ),
          )
        else
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.5),
              shape: BoxShape.circle,
            ),
          ),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }
}

/// Selector satuan pill yang menyatu halus dengan background
class UnitSelectorPill extends StatelessWidget {
  const UnitSelectorPill({
    super.key,
    required this.unit,
    required this.onChanged,
  });

  final SoundUnit unit;
  final ValueChanged<SoundUnit> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF121419),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF1E222A)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _option('dB (Desibel)', SoundUnit.db),
          _option('RMS (Pascal)', SoundUnit.rms),
        ],
      ),
    );
  }

  Widget _option(String label, SoundUnit target) {
    final active = unit == target;
    return GestureDetector(
      onTap: () => onChanged(target),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF222732) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? AppColors.textPrimary : AppColors.textMuted,
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

/// Meter horizontal bergaya audio visualizer tanpa kotak/card
class LevelMeter extends StatelessWidget {
  const LevelMeter({super.key, required this.db});

  final double? db;

  static const double minDb = 30;
  static const double maxDb = 120;

  @override
  Widget build(BuildContext context) {
    final value = db;
    final fraction = value == null
        ? 0.0
        : ((value - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);

    // Tanpa animasi tween: bar langsung mengikuti data terbaru.
    return SizedBox(
      height: 48,
      width: double.infinity,
      child: CustomPaint(
        painter: _MeterPainter(fraction: fraction, active: value != null),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter({required this.fraction, required this.active});

  final double fraction;
  final bool active;

  static const int _bars = 44;
  static const double _gap = 3.5;
  static const double _labelHeight = 18;

  @override
  void paint(Canvas canvas, Size size) {
    final barsHeight = size.height - _labelHeight;
    final barWidth = (size.width - _gap * (_bars - 1)) / _bars;
    final paint = Paint();

    for (var i = 0; i < _bars; i++) {
      final position = (i + 0.5) / _bars;
      final db = LevelMeter.minDb + position * (LevelMeter.maxDb - LevelMeter.minDb);
      final lit = active && position <= fraction;
      final height = lit ? barsHeight : barsHeight * 0.35;
      final left = i * (barWidth + _gap);

      paint.color = lit
          ? NoiseLevel.fromDb(db).color
          : const Color(0xFF1E232B).withValues(alpha: 0.7);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, barsHeight - height, barWidth, height),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }

    for (final tick in const [30.0, 60.0, 85.0, 120.0]) {
      final x = (tick - LevelMeter.minDb) /
          (LevelMeter.maxDb - LevelMeter.minDb) *
          size.width;
      final painter = TextPainter(
        text: TextSpan(
          text: '${tick.toStringAsFixed(0)} dB',
          style: AppText.number(
            10.5,
            color: AppColors.textMuted,
            weight: FontWeight.w500,
          ).copyWith(letterSpacing: 0),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = (x - painter.width / 2).clamp(0.0, size.width - painter.width);
      painter.paint(canvas, Offset(dx, barsHeight + 6));
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.fraction != fraction || old.active != active;
}

/// Statistik ringkas tanpa kotak: Puncak, Rata-rata, dan Parameter alternatif
class StatsRow extends StatelessWidget {
  const StatsRow({
    super.key,
    required this.history,
    required this.unit,
    required this.db,
    required this.rms,
  });

  final List<SoundReading> history;
  final SoundUnit unit;
  final double? db;
  final double? rms;

  @override
  Widget build(BuildContext context) {
    final values = history.map((r) => r.valueFor(unit)).toList();
    final peak = values.isEmpty ? null : values.reduce(math.max);
    final avg = values.isEmpty
        ? null
        : values.reduce((a, b) => a + b) / values.length;

    final otherUnit = unit == SoundUnit.db ? SoundUnit.rms : SoundUnit.db;
    final otherValue = otherUnit == SoundUnit.db ? db : rms;

    return IntrinsicHeight(
      child: Row(
        children: [
          Expanded(child: _cell('PUNCAK', peak, unit)),
          _divider(),
          Expanded(child: _cell('RATA-RATA', avg, unit)),
          _divider(),
          Expanded(
            child: _cell(
              otherUnit == SoundUnit.db ? 'DB SAAT INI' : 'RMS SAAT INI',
              otherValue,
              otherUnit,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Container(
        width: 1,
        margin: const EdgeInsets.symmetric(vertical: 4),
        color: const Color(0xFF1B1E26),
      );

  Widget _cell(String label, double? value, SoundUnit u) {
    final formatted = value == null ? null : formatValue(value, u);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Column(
        children: [
          Text(
            label,
            style: AppText.label.copyWith(fontSize: 9.5, letterSpacing: 1.1),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 7),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: formatted?.value ?? '--',
                    style: AppText.number(
                      20,
                      weight: FontWeight.w400,
                      color: formatted == null
                          ? AppColors.textMuted
                          : AppColors.textPrimary,
                    ).copyWith(letterSpacing: -0.3),
                  ),
                  if (formatted != null)
                    TextSpan(
                      text: ' ${formatted.unit}',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
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

/// Riwayat pembacaan dalam bentuk sparkline bersih tanpa card
class HistorySection extends StatelessWidget {
  const HistorySection({
    super.key,
    required this.values,
    required this.color,
    required this.minSpan,
    required this.spanLabel,
    this.maxPoints = 60,
  });

  final List<double> values;
  final Color color;
  final double minSpan;
  final String spanLabel;
  final int maxPoints;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('TREN KEBISINGAN', style: AppText.label),
            const Spacer(),
            Text(
              spanLabel,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 52,
          width: double.infinity,
          child: CustomPaint(
            painter: _SparklinePainter(
              values: values,
              color: color,
              minSpan: minSpan,
              maxPoints: maxPoints,
            ),
          ),
        ),
      ],
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.color,
    required this.minSpan,
    required this.maxPoints,
  });

  final List<double> values;
  final Color color;
  final double minSpan;
  final int maxPoints;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) {
      final dash = Paint()
        ..color = const Color(0xFF1E222A)
        ..strokeWidth = 1.2;
      final y = size.height / 2;
      for (var x = 0.0; x < size.width; x += 9) {
        canvas.drawLine(
            Offset(x, y), Offset(math.min(x + 4, size.width), y), dash);
      }
      return;
    }

    final lo = values.reduce(math.min);
    final hi = values.reduce(math.max);
    final span = math.max(hi - lo, minSpan);
    final mid = (hi + lo) / 2;
    final floor = mid - span / 2;

    const pad = 6.0;
    final usable = size.height - pad * 2;
    final step = size.width / (maxPoints - 1);

    final points = <Offset>[
      for (var i = 0; i < values.length; i++)
        Offset(
          size.width - (values.length - 1 - i) * step,
          pad + usable * (1 - (values[i] - floor) / span),
        ),
    ];

    final line = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      line.lineTo(p.dx, p.dy);
    }

    final fill = Path.from(line)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.16), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    final last = points.last;
    canvas.drawCircle(last, 6, Paint()..color = color.withValues(alpha: 0.16));
    canvas.drawCircle(last, 2.8, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.color != color;
}
