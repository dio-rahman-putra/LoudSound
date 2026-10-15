import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
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

  // Firebase bersifat opsional (hanya untuk push FCM). Notifikasi peringatan
  // kebisingan dibuat lokal sehingga tetap jalan walau Firebase gagal init.
  try {
    final firebaseOptions = DefaultFirebaseOptions.currentPlatform;
    if (firebaseOptions != null) {
      await Firebase.initializeApp(options: firebaseOptions);
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      // Memakai konfigurasi native dari android/app/google-services.json
      await Firebase.initializeApp();
    }
  } catch (e) {
    debugPrint('[Firebase] Tidak aktif: $e');
  }

  try {
    await FirebaseNotificationService.initialize();
  } catch (e) {
    debugPrint('[Notif] Gagal inisialisasi: $e');
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
  /// Tampilan angka & meter diperbarui LANGSUNG setiap paket BLE diterima
  /// (tanpa timer dan tanpa animasi tween) agar delay minimum.
  /// Timer ringan di bawah hanya untuk riwayat grafik & deteksi data tertunda.
  static const _historySampleInterval = Duration(milliseconds: 500);
  static const _historyLength = 120;
  static const _staleAfter = Duration(seconds: 3);
  static const _alertRepeat = Duration(seconds: 30);

  final BleIotService _bleService = BleIotService();
  final List<SoundReading> _history = [];

  Timer? _sampleTimer;
  int _seenTick = 0;
  DateTime? _lastDataAt;
  bool _stale = false;
  bool _showTrend = false;

  bool _notificationsEnabled = false;
  bool _requestingNotifications = false;
  bool _wasLoud = false;
  DateTime? _lastAlertAt;
  SoundUnit _unit = SoundUnit.db;

  bool get _paired =>
      _bleService.connectionState == BleDeviceConnectionState.connected;

  @override
  void initState() {
    super.initState();
    _seenTick = _bleService.readingTick;
    _bleService.addListener(_onBleUpdate);
    if (_paired) {
      if (_bleService.latestDecibels != null) _lastDataAt = DateTime.now();
      _startSampling();
    }
    _restoreNotificationState();
  }

  @override
  void dispose() {
    _bleService.removeListener(_onBleUpdate);
    _stopSampling();
    super.dispose();
  }

  /// Jika izin notifikasi sudah diberikan sebelumnya, peringatan langsung aktif.
  Future<void> _restoreNotificationState() async {
    final granted = await FirebaseNotificationService.hasPermission();
    if (!mounted || !granted) return;
    setState(() => _notificationsEnabled = true);
  }

  /// Dipanggil setiap ada perubahan status BLE atau telemetri dari service
  void _onBleUpdate() {
    if (!mounted) return;

    if (_paired) {
      _startSampling();
      if (_bleService.readingTick != _seenTick) {
        _seenTick = _bleService.readingTick;
        _lastDataAt = DateTime.now();
        _stale = false;
        _maybeAlert();
      }
    } else {
      _stopSampling();
    }
    setState(() {});
  }

  void _startSampling() {
    if (!_paired) return;
    _sampleTimer ??= Timer.periodic(_historySampleInterval, _onSampleTick);
  }

  /// Menghentikan timer dan mereset tampilan jika koneksi IoT terputus
  void _stopSampling() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _seenTick = _bleService.readingTick;
    _lastDataAt = null;
    _stale = false;
    _wasLoud = false;
    _history.clear();
  }

  /// Menyimpan sampel ke riwayat grafik & mengecek data tertunda.
  void _onSampleTick(Timer timer) {
    if (!mounted) return;

    if (!_paired) {
      setState(_stopSampling);
      return;
    }

    final db = _bleService.latestDecibels;
    final rms = _bleService.latestRms;
    final lastAt = _lastDataAt;

    setState(() {
      _stale = lastAt != null &&
          DateTime.now().difference(lastAt) > _staleAfter;

      if (!_stale && db != null && rms != null && lastAt != null) {
        _history.add(SoundReading(db, rms));
        if (_history.length > _historyLength) {
          _history.removeAt(0);
        }
      }
    });
  }

  /// Kirim notifikasi saat suara melewati ambang (sekali saat mulai berisik,
  /// lalu diulang tiap 30 detik selama masih berisik).
  void _maybeAlert() {
    final db = _bleService.latestDecibels;
    final loud = _bleService.isLoudNow ||
        (db != null && db >= SoundCalibration.loudThresholdDb);

    if (!loud) {
      _wasLoud = false;
      return;
    }

    final now = DateTime.now();
    final lastAlert = _lastAlertAt;
    final shouldNotify = !_wasLoud ||
        (lastAlert != null && now.difference(lastAlert) >= _alertRepeat);
    _wasLoud = true;

    if (!_notificationsEnabled || !shouldNotify) return;

    _lastAlertAt = now;
    FirebaseNotificationService.showNoiseAlert(
      db: db ?? SoundCalibration.loudThresholdDb,
    );
  }

  HeroStatus get _heroStatus {
    if (!_paired) return HeroStatus.offline;
    if (_bleService.latestDecibels == null) return HeroStatus.waiting;
    return _stale ? HeroStatus.stale : HeroStatus.live;
  }

  String get _historySpanLabel {
    if (_history.length < 2) return '—';
    final seconds =
        ((_history.length - 1) * _historySampleInterval.inMilliseconds / 1000)
            .round();
    if (seconds < 60) return '$seconds dtk terakhir';
    return '${(seconds / 60).toStringAsFixed(seconds % 60 == 0 ? 0 : 1)} menit terakhir';
  }

  Future<void> _toggleNotifications() async {
    if (_requestingNotifications) return;

    // Sudah aktif -> matikan peringatan
    if (_notificationsEnabled) {
      setState(() => _notificationsEnabled = false);
      _showSnack('Notifikasi kebisingan dimatikan.');
      return;
    }

    setState(() => _requestingNotifications = true);
    final result = await FirebaseNotificationService.enableNotifications();
    if (!mounted) return;
    setState(() {
      _requestingNotifications = false;
      _notificationsEnabled = result == NotificationPermissionResult.enabled;
      if (_notificationsEnabled) {
        _wasLoud = false;
        _lastAlertAt = null;
      }
    });

    final message = switch (result) {
      NotificationPermissionResult.enabled =>
        'Notifikasi aktif. Anda akan diberi tahu saat suara melewati 85 dB.',
      NotificationPermissionResult.denied =>
        'Izin notifikasi ditolak. Aktifkan lewat Pengaturan > Aplikasi > LoudSound > Notifikasi.',
      NotificationPermissionResult.unsupportedPlatform =>
        'Notifikasi tersedia di platform Android dan iOS.',
    };
    _showSnack(message);

    if (result == NotificationPermissionResult.enabled) {
      await FirebaseNotificationService.showActivatedNotification();
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // Nilai langsung dari service (realtime, tanpa batching timer)
    final db = _paired ? _bleService.latestDecibels : null;
    final rms = _paired ? _bleService.latestRms : null;
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
                              onNotificationsPressed: _toggleNotifications,
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

                            // 2. CENTERPIECE HERO: Angka dB / RMS di Tengah Layar (Realtime)
                            Expanded(
                              child: Center(
                                child: HeroReading(
                                  db: db,
                                  rms: rms,
                                  unit: _unit,
                                  onUnitChanged: (value) =>
                                      setState(() => _unit = value),
                                  status: _heroStatus,
                                  iotStatus:
                                      _paired ? _bleService.latestStatus : null,
                                ),
                              ),
                            ),

                            // 3. BOTTOM SECTION: Meter Audio VU & Statistik Ringkas (Realtime)
                            _BottomSection(
                              barDb: db,
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
                : 'Uji simulasi realtime',
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
                ? 'Matikan notifikasi'
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
        // Visualizer Audio VU Meter (Realtime, tanpa animasi tween)
        LevelMeter(db: barDb),
        const SizedBox(height: 18),

        // 3 Metrik Esensial: Puncak, Rata-rata, dan Parameter Alternatif
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
