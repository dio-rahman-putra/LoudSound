import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'ble_iot_service.dart';
import 'ble_provisioning_sheet.dart';
import 'firebase_notification_service.dart';
import 'firebase_options.dart';
import 'sound_widgets.dart';
import 'splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle.light.copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: AppColors.background,
    ),
  );
  final firebaseOptions = DefaultFirebaseOptions.currentPlatform;
  if (firebaseOptions != null) {
    await Firebase.initializeApp(options: firebaseOptions);
    await FirebaseNotificationService.initialize();
  }
  runApp(const LoudSoundApp());
}

class LoudSoundApp extends StatelessWidget {
  const LoudSoundApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LoudSound',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const SplashScreen(),
    );
  }
}

class SoundDashboardPage extends StatefulWidget {
  const SoundDashboardPage({super.key});

  @override
  State<SoundDashboardPage> createState() => _SoundDashboardPageState();
}

class _SoundDashboardPageState extends State<SoundDashboardPage> {
  /// Interval penyegaran:
  /// - Bar horizontal bawah: 1 detik (realtime per detik agar responsif & enak dilihat)
  /// - Angka utama dB & RMS di tengah: 2 detik (stabil dan tetap relevan tanpa flicker)
  static const _barInterval = Duration(seconds: 1);
  static const _historyLength = 60;
  static const _staleAfterMissedTicks = 3;

  final BleIotService _bleService = BleIotService();
  final List<SoundReading> _history = [];

  Timer? _oneSecondTimer;
  double? _barDb; // Nilai realtime untuk bar horizontal (refresh per 1 detik)
  double? _shownDb; // Nilai angka desibel tengah (refresh per 2 detik)
  double? _shownRms; // Nilai angka RMS tengah (refresh per 2 detik)
  int _secondsCounter = 0;
  int _committedTick = 0;
  int _missedTicks = 0;
  bool _stale = false;
  bool _showTrend = false;

  bool _notificationsEnabled = false;
  bool _requestingNotifications = false;
  SoundUnit _unit = SoundUnit.db;

  bool get _paired =>
      _bleService.connectionState == BleDeviceConnectionState.connected;

  @override
  void initState() {
    super.initState();
    _committedTick = _bleService.readingTick;
    _bleService.addListener(_onBleUpdate);
    if (_paired) {
      _startRefresh();
    }
  }

  @override
  void dispose() {
    _bleService.removeListener(_onBleUpdate);
    _stopRefresh();
    super.dispose();
  }

  /// Dipanggil setiap ada perubahan status BLE atau telemetri dari service
  void _onBleUpdate() {
    if (!mounted) return;

    if (_paired) {
      _startRefresh();
      // Segera tampilkan pembacaan pertama untuk bar dan angka
      if (_barDb == null && _bleService.latestDecibels != null) {
        _barDb = _bleService.latestDecibels;
      }
      if (_shownDb == null && _bleService.readingTick != _committedTick) {
        _commitReading();
      }
    } else {
      _stopRefresh();
    }
    setState(() {});
  }

  /// Memulai timer refresh 1 detik (HANYA saat perangkat IoT sudah ter-pair)
  void _startRefresh() {
    if (!_paired) return;
    _oneSecondTimer ??= Timer.periodic(_barInterval, _onOneSecondTick);
  }

  /// Menghentikan refresh timer dan mereset tampilan jika koneksi IoT terputus
  void _stopRefresh() {
    _oneSecondTimer?.cancel();
    _oneSecondTimer = null;
    _committedTick = _bleService.readingTick;
    _barDb = null;
    _shownDb = null;
    _shownRms = null;
    _secondsCounter = 0;
    _missedTicks = 0;
    _stale = false;
    _history.clear();
  }

  /// Mengambil sampel data sensor terbaru untuk angka tengah (dB & RMS)
  void _commitReading() {
    final db = _bleService.latestDecibels;
    final rms = _bleService.latestRms;
    if (db == null || rms == null) return;

    _committedTick = _bleService.readingTick;
    _missedTicks = 0;
    _stale = false;
    _shownDb = db;
    _shownRms = rms;
    _history.add(SoundReading(db, rms));
    if (_history.length > _historyLength) {
      _history.removeAt(0);
    }
  }

  /// Callback tiap 1 detik:
  /// - Bar bawah diperbarui SETIAP 1 DETIK (Realtime & responsif)
  /// - Angka tengah dB & RMS diperbarui SETIAP 2 DETIK (Stabil)
  void _onOneSecondTick(Timer timer) {
    if (!mounted) return;

    // Pastikan kondisi: perangkat IoT WAJIB sudah ke-pair
    if (!_paired) {
      setState(_stopRefresh);
      return;
    }

    _secondsCounter++;

    setState(() {
      // 1. Perbarui Bar Spektrum Bawah (SETIAP 1 DETIK)
      final currentDb = _bleService.latestDecibels;
      if (currentDb != null) {
        _barDb = currentDb;
      }

      // 2. Perbarui Angka Utama dB & RMS di Tengah (SETIAP 2 DETIK)
      if (_secondsCounter % 2 == 0) {
        if (_bleService.readingTick != _committedTick) {
          _commitReading();
        } else if (_shownDb != null) {
          _missedTicks++;
          if (_missedTicks >= _staleAfterMissedTicks) {
            _stale = true;
          }
        }
      }
    });
  }

  HeroStatus get _heroStatus {
    if (!_paired) return HeroStatus.offline;
    if (_shownDb == null) return HeroStatus.waiting;
    return _stale ? HeroStatus.stale : HeroStatus.live;
  }

  String get _historySpanLabel {
    if (_history.length < 2) return '—';
    final seconds = (_history.length - 1) * 2;
    if (seconds < 60) return '$seconds dtk terakhir';
    return '${(seconds / 60).toStringAsFixed(seconds % 60 == 0 ? 0 : 1)} menit terakhir';
  }

  Future<void> _enableNotifications() async {
    if (_requestingNotifications) return;

    setState(() => _requestingNotifications = true);
    final result = await FirebaseNotificationService.enableNotifications();
    if (!mounted) return;
    setState(() {
      _requestingNotifications = false;
      _notificationsEnabled = result == NotificationPermissionResult.enabled;
    });

    final message = switch (result) {
      NotificationPermissionResult.enabled =>
        'Notifikasi kebisingan berhasil diaktifkan.',
      NotificationPermissionResult.denied =>
        'Izin notifikasi belum diberikan. Periksa pengaturan perangkat.',
      NotificationPermissionResult.notConfigured =>
        'Firebase belum dikonfigurasi. Ikuti panduan di README.md.',
      NotificationPermissionResult.unsupportedPlatform =>
        'Notifikasi Firebase tersedia di platform Android dan iOS.',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final db = _shownDb;
    final rms = _shownRms;
    final level = db == null ? null : NoiseLevel.fromDb(db);
    final deviceName = _bleService.currentDeviceName;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: IntrinsicHeight(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 1. TOP BAR: Branding, Status Pairing IoT, Demo Tester, dan Notifikasi
                            _DashboardTopBar(
                              paired: _paired,
                              deviceName: deviceName,
                              wifiStatus: _bleService.iotWifiStatus,
                              isMock: _bleService.isMockDevice,
                              notificationsEnabled: _notificationsEnabled,
                              isLoadingNotifications: _requestingNotifications,
                              onNotificationsPressed: _enableNotifications,
                              onDevicePressed: () =>
                                  BleProvisioningSheet.show(context),
                              onToggleDemo: () {
                                if (_paired && _bleService.isMockDevice) {
                                  _bleService.disconnect();
                                } else {
                                  _bleService.connectDemoDevice();
                                }
                              },
                            ),

                            // 2. CENTERPIECE HERO: Angka DB / RMS di Tengah Layar (Refresh Tiap 2 Detik)
                            Expanded(
                              child: Center(
                                child: HeroReading(
                                  db: db,
                                  rms: rms,
                                  unit: _unit,
                                  onUnitChanged: (value) =>
                                      setState(() => _unit = value),
                                  status: _heroStatus,
                                  refreshSeconds: 2,
                                  iotStatus: _bleService.latestStatus,
                                ),
                              ),
                            ),

                            // 3. BOTTOM SECTION: Meter Audio VU (Realtime 1s) & Statistik Ringkas (2s)
                            _BottomSection(
                              barDb: _barDb,
                              db: db,
                              rms: rms,
                              history: _history,
                              unit: _unit,
                              level: level,
                              showTrend: _showTrend,
                              onToggleTrend: () =>
                                  setState(() => _showTrend = !_showTrend),
                              spanLabel: _historySpanLabel,
                              historyLength: _historyLength,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Header bar mengambang yang menyatu mulus dengan background
class _DashboardTopBar extends StatelessWidget {
  const _DashboardTopBar({
    required this.paired,
    required this.deviceName,
    required this.wifiStatus,
    required this.isMock,
    required this.notificationsEnabled,
    required this.isLoadingNotifications,
    required this.onNotificationsPressed,
    required this.onDevicePressed,
    required this.onToggleDemo,
  });

  final bool paired;
  final String? deviceName;
  final String wifiStatus;
  final bool isMock;
  final bool notificationsEnabled;
  final bool isLoadingNotifications;
  final VoidCallback onNotificationsPressed;
  final VoidCallback onDevicePressed;
  final VoidCallback onToggleDemo;

  @override
  Widget build(BuildContext context) {
    final statusColor = paired ? AppColors.quiet : AppColors.textMuted;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          // Logo Minimalis
          GestureDetector(
            onTap: onDevicePressed,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                    boxShadow: paired
                        ? [
                            BoxShadow(
                              color: statusColor.withValues(alpha: 0.7),
                              blurRadius: 8,
                            )
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 9),
                const Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: 'loud',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextSpan(
                        text: 'sound',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                    ],
                  ),
                  style: TextStyle(fontSize: 18, letterSpacing: -0.5),
                ),
              ],
            ),
          ),
          const Spacer(),

          // Capsule Status Perangkat IoT
          InkWell(
            onTap: onDevicePressed,
            borderRadius: BorderRadius.circular(20),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                color: paired
                    ? const Color(0xFF13171F)
                    : const Color(0xFF101216),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: paired
                      ? AppColors.quiet.withValues(alpha: 0.3)
                      : const Color(0xFF1C2028),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    paired ? Icons.bluetooth_connected : Icons.bluetooth,
                    size: 14,
                    color: statusColor,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    paired ? (deviceName ?? 'IoT Ter-Pair') : 'Pair IoT',
                    style: TextStyle(
                      color: paired
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Tombol Uji Coba Demo / Simulasi Sensor
          IconButton(
            tooltip: paired && isMock
                ? 'Putuskan demo'
                : 'Uji simulasi 2s refresh',
            onPressed: onToggleDemo,
            style: IconButton.styleFrom(
              fixedSize: const Size(36, 36),
              foregroundColor: paired && isMock
                  ? AppColors.normal
                  : AppColors.textMuted,
            ),
            icon: Icon(
              paired && isMock ? Icons.bolt_rounded : Icons.bolt_outlined,
              size: 19,
            ),
          ),

          // Tombol Notifikasi
          IconButton(
            tooltip: notificationsEnabled
                ? 'Notifikasi aktif'
                : 'Aktifkan notifikasi',
            onPressed: onNotificationsPressed,
            style: IconButton.styleFrom(
              fixedSize: const Size(36, 36),
              foregroundColor: notificationsEnabled
                  ? AppColors.quiet
                  : AppColors.textSecondary,
            ),
            icon: isLoadingNotifications
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  )
                : Icon(
                    notificationsEnabled
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_none_rounded,
                    size: 20,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Bagian Bawah: Meter Audio Visualizer & Baris Statistik Bebas Card
class _BottomSection extends StatelessWidget {
  const _BottomSection({
    required this.barDb,
    required this.db,
    required this.rms,
    required this.history,
    required this.unit,
    required this.level,
    required this.showTrend,
    required this.onToggleTrend,
    required this.spanLabel,
    required this.historyLength,
  });

  final double? barDb;
  final double? db;
  final double? rms;
  final List<SoundReading> history;
  final SoundUnit unit;
  final NoiseLevel? level;
  final bool showTrend;
  final VoidCallback onToggleTrend;
  final String spanLabel;
  final int historyLength;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Visualizer Audio VU Meter (Realtime 1 detik dari kiri ke kanan)
        LevelMeter(db: barDb),
        const SizedBox(height: 18),

        // 3 Metrik Esensial: Puncak, Rata-rata, dan Parameter Alternatif (Refresh 2 detik)
        StatsRow(
          history: history,
          unit: unit,
          db: db,
          rms: rms,
        ),
        const SizedBox(height: 14),

        // Toggle dan Tampilan Tren Sparkline Riwayat (Opsional/Bisa Dibuka)
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: onToggleTrend,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      showTrend
                          ? Icons.expand_less_rounded
                          : Icons.show_chart_rounded,
                      size: 15,
                      color: AppColors.textMuted,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      showTrend ? 'Sembunyikan grafik' : 'Grafik riwayat',
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

        if (showTrend) ...[
          const SizedBox(height: 8),
          HistorySection(
            values: history.map((r) => r.valueFor(unit)).toList(),
            color: level?.color ?? AppColors.textMuted,
            minSpan: unit == SoundUnit.db ? 8 : 0.02,
            spanLabel: spanLabel,
            maxPoints: historyLength,
          ),
        ],
      ],
    );
  }
}
