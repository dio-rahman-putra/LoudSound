import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// UUID Service & Characteristic BLE untuk IoT LoudSound (ESP32 DETEKSI_KEBISINGAN_IOT.ino)
class BleUuids {
  // Service UUID utama dari DETEKSI_KEBISINGAN_IOT.ino
  static final Guid serviceUuid =
      Guid('4fa8c001-124e-423a-bc3f-923de9dc001e');

  // Service UUID legacy / cadangan
  static final Guid legacyServiceUuid =
      Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');

  // Characteristic telemetri suara utama (Read/Notify)
  static final Guid decibelCharacteristicUuid =
      Guid('beb5483e-36e1-4688-b7f5-ea07361b26a8');

  // Characteristic telemetri cadangan (firmware legacy)
  static final Guid altDecibelCharacteristicUuid =
      Guid('beb5483e-36e1-4688-b7f5-ea07361b26aa');

  // Characteristic konfigurasi Wi-Fi (Write) - kredensial dikirim app ke ESP32
  static final Guid wifiConfigCharacteristicUuid =
      Guid('beb5483e-36e1-4688-b7f5-ea07361b26b1');

  // Characteristic status Wi-Fi (Read/Notify) - hasil koneksi dikirim ESP32 ke app
  static final Guid wifiStatusCharacteristicUuid =
      Guid('beb5483e-36e1-4688-b7f5-ea07361b26b2');

  // Status Wi-Fi pada firmware legacy (lib/esp32_loudsound_ble_wifi.ino)
  static final Guid legacyWifiStatusCharacteristicUuid =
      Guid('beb5483e-36e1-4688-b7f5-ea07361b26a9');
}

/// Konstanta kalibrasi suara. Harus selaras dengan firmware ESP32
/// (mikrofon INMP441: -26 dBFS @ 94 dB SPL).
abstract final class SoundCalibration {
  /// dB SPL acuan saat sensitivitas mikrofon diukur.
  static const double refDb = 94.0;

  /// Batas bawah/atas dB SPL yang valid untuk mikrofon INMP441.
  static const double minDb = 30.0;
  static const double maxDb = 120.0;

  /// Ambang "TERLALU BERISIK" (sama dengan firmware & NoiseLevel.loud).
  static const double loudThresholdDb = 85.0;

  /// Nilai RMS firmware LAMA (RMS 24-bit / 10000) pada 94 dB SPL.
  /// = 10^(-26/20) * 2^23 / sqrt(2) / 10000
  static const double legacyRmsAtRefDb = 29.7284;

  static const String statusLoud = 'TERLALU BERISIK';
  static const String statusNormal = 'NORMAL';

  /// Konversi RMS skala firmware lama menjadi dB SPL terkalibrasi.
  static double legacyRmsToDb(double scaledRms) {
    if (scaledRms <= 0) return minDb;
    final db = refDb + 20.0 * (math.log(scaledRms / legacyRmsAtRefDb) / math.ln10);
    return db.clamp(minDb, maxDb).toDouble();
  }

  /// dB SPL -> tekanan suara RMS dalam Pascal (p = 20 µPa * 10^(dB/20)).
  static double dbToPascal(double db) {
    return math.pow(10.0, (db - refDb) / 20.0).toDouble();
  }
}

/// Hasil parsing satu paket telemetri dari ESP32.
class TelemetrySample {
  const TelemetrySample({
    required this.db,
    required this.rms,
    required this.status,
  });

  /// Tingkat suara terkalibrasi (dB SPL).
  final double db;

  /// Tekanan suara RMS dalam Pascal.
  final double rms;

  /// Status alarm ('NORMAL' / 'TERLALU BERISIK').
  final String status;
}

enum BleDeviceConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

class DiscoveredIotDevice {
  final BluetoothDevice device;
  final String name;
  final int rssi;
  final bool isLikelyIot;

  DiscoveredIotDevice({
    required this.device,
    required this.name,
    required this.rssi,
    this.isLikelyIot = false,
  });
}

class BleIotService with ChangeNotifier {
  static final BleIotService _instance = BleIotService._internal();
  factory BleIotService() => _instance;
  BleIotService._internal();

  BluetoothDevice? _connectedDevice;
  BluetoothDevice? get connectedDevice => _connectedDevice;

  BleDeviceConnectionState _connectionState =
      BleDeviceConnectionState.disconnected;
  BleDeviceConnectionState get connectionState => _connectionState;

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  final List<DiscoveredIotDevice> _discoveredDevices = [];
  List<DiscoveredIotDevice> get discoveredDevices =>
      List.unmodifiable(_discoveredDevices);

  /// Pesan kesalahan terakhir (izin ditolak, Bluetooth mati, dsb.) untuk UI.
  String? _lastError;
  String? get lastError => _lastError;

  String? _connectedWifiSsid;
  String? get connectedWifiSsid => _connectedWifiSsid;

  String _iotWifiStatus = 'Belum terhubung ke Wi-Fi';
  String get iotWifiStatus => _iotWifiStatus;

  /// Tekanan suara RMS (Pascal).
  double? _latestRms;
  double? get latestRms => _latestRms;

  /// Tingkat suara terkalibrasi (dB SPL).
  double? _latestDecibels;
  double? get latestDecibels => _latestDecibels;

  String? _latestStatus;
  String? get latestStatus => _latestStatus;

  bool get isLoudNow => _latestStatus == SoundCalibration.statusLoud;

  /// Mengurai payload telemetri dari ESP32 menjadi dB SPL terkalibrasi.
  ///
  /// Format yang didukung:
  ///  - JSON baru  : {"db":74.3,"rms":0.01234,"status":"NORMAL"}
  ///  - JSON lama  : {"rms":74.2,"status":"NORMAL"}  (skala RMS lama, dikonversi)
  ///  - JSON TERPOTONG (MTU kecil) -> field diambil dengan regex
  ///  - "DB:68.5", "RMS:74.2", atau angka tunggal (dianggap dB)
  @visibleForTesting
  static TelemetrySample? parseTelemetry(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    double? db;
    double? legacyRms;
    String? status;

    double? numberFor(String key) {
      final m = RegExp('"$key"\\s*:\\s*(-?\\d+(?:\\.\\d+)?)').firstMatch(text);
      return m == null ? null : double.tryParse(m.group(1)!);
    }

    if (text.startsWith('{')) {
      var decoded = false;
      if (text.endsWith('}')) {
        try {
          final json = jsonDecode(text);
          if (json is Map<String, dynamic>) {
            decoded = true;
            if (json['db'] is num) db = (json['db'] as num).toDouble();
            if (json['rms'] is num) legacyRms = (json['rms'] as num).toDouble();
            if (json['status'] != null) status = json['status'].toString();
          }
        } catch (_) {}
      }
      if (!decoded) {
        // Payload terpotong: selamatkan field yang masih utuh.
        db = numberFor('db');
        legacyRms = numberFor('rms');
        status = RegExp('"status"\\s*:\\s*"([^"]*)"').firstMatch(text)?.group(1);
      }
    } else {
      final upper = text.toUpperCase();
      if (upper.startsWith('DB:')) {
        db = double.tryParse(text.substring(3).trim());
      } else if (upper.startsWith('RMS:')) {
        legacyRms = double.tryParse(text.substring(4).trim());
      } else {
        db = double.tryParse(text);
      }
    }

    final double finalDb;
    if (db != null) {
      finalDb = db.clamp(SoundCalibration.minDb, SoundCalibration.maxDb).toDouble();
    } else if (legacyRms != null) {
      finalDb = SoundCalibration.legacyRmsToDb(legacyRms);
    } else {
      return null;
    }

    final resolvedStatus = (status != null && status.isNotEmpty)
        ? status
        : (finalDb >= SoundCalibration.loudThresholdDb
            ? SoundCalibration.statusLoud
            : SoundCalibration.statusNormal);

    return TelemetrySample(
      db: finalDb,
      rms: SoundCalibration.dbToPascal(finalDb),
      status: resolvedStatus,
    );
  }

  int _readingTick = 0;

  /// Bertambah setiap kali ada pembacaan suara baru (dipakai UI untuk riwayat).
  int get readingTick => _readingTick;

  bool _isMockDevice = false;
  bool get isMockDevice => _isMockDevice;
  Timer? _mockSensorTimer;
  String? _mockDeviceName;

  String? get currentDeviceName {
    if (_isMockDevice) return _mockDeviceName ?? 'Noise_Monitor';
    final dev = _connectedDevice;
    if (dev == null) return null;
    return dev.platformName.isNotEmpty ? dev.platformName : dev.remoteId.str;
  }

  /// Menghubungkan perangkat demo/simulasi
  void connectDemoDevice({String name = 'Noise_Monitor'}) {
    unawaited(disconnect());
    _isMockDevice = true;
    _mockDeviceName = name;
    _connectionState = BleDeviceConnectionState.connected;
    _iotWifiStatus = 'BLE Terhubung (Sensor I2S Aktif)';
    _connectedWifiSsid = null;

    _applySample(const TelemetrySample(
      db: 58.4,
      rms: 0.0017,
      status: SoundCalibration.statusNormal,
    ));

    _mockSensorTimer?.cancel();
    // Mensimulasikan ESP32 yang mengirim telemetri realtime setiap 250 ms
    _mockSensorTimer =
        Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (_connectionState != BleDeviceConnectionState.connected ||
          !_isMockDevice) {
        timer.cancel();
        return;
      }
      final tick = timer.tick;
      final base = 62.0 + math.sin(tick * 0.07) * 14.0;
      final noise = (math.Random().nextDouble() - 0.5) * 6.0;
      final spike = (tick % 60 < 8) ? 26.0 : 0.0;
      final db = (base + noise + spike)
          .clamp(SoundCalibration.minDb, SoundCalibration.maxDb)
          .toDouble();
      final loud = db >= SoundCalibration.loudThresholdDb;

      _applySample(TelemetrySample(
        db: double.parse(db.toStringAsFixed(1)),
        rms: SoundCalibration.dbToPascal(db),
        status: loud
            ? SoundCalibration.statusLoud
            : SoundCalibration.statusNormal,
      ));
    });
  }

  void _applySample(TelemetrySample sample) {
    _latestDecibels = sample.db;
    _latestRms = sample.rms;
    _latestStatus = sample.status;
    _readingTick++;
    notifyListeners();
  }

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _isScanningSub;
  StreamSubscription<BluetoothConnectionState>? _deviceConnSub;
  StreamSubscription<List<int>>? _wifiStatusSub;
  StreamSubscription<List<int>>? _decibelSub;

  BluetoothCharacteristic? _wifiConfigChar;
  BluetoothCharacteristic? _wifiStatusChar;
  BluetoothCharacteristic? _decibelChar;

  BluetoothCharacteristic? get wifiConfigChar => _wifiConfigChar;
  BluetoothCharacteristic? get wifiStatusChar => _wifiStatusChar;
  BluetoothCharacteristic? get decibelChar => _decibelChar;

  /// True bila firmware perangkat menyediakan karakteristik konfigurasi Wi-Fi.
  bool get supportsWifiProvisioning => _wifiConfigChar != null;

  /// True bila karakteristik telemetri suara ditemukan.
  bool get hasTelemetry => _decibelChar != null;

  /// Meminta izin yang dibutuhkan: hanya Bluetooth ("Perangkat sekitar") + Wi-Fi.
  ///
  /// - Android 12+ : BLUETOOTH_SCAN (neverForLocation) + BLUETOOTH_CONNECT +
  ///   NEARBY_WIFI_DEVICES (Android 13+). TIDAK memerlukan izin lokasi/GPS.
  /// - Android 11-: izin lokasi diminta otomatis oleh flutter_blue_plus saat scan
  ///   (batasan sistem Android untuk BLE versi lama).
  Future<bool> requestPermissions() async {
    if (kIsWeb) {
      _lastError = 'Bluetooth tidak didukung di web.';
      return false;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.nearbyWifiDevices,
      ].request();

      final scan = statuses[Permission.bluetoothScan];
      final conn = statuses[Permission.bluetoothConnect];

      final scanOk = scan?.isGranted ?? true;
      final connOk = conn?.isGranted ?? true;

      if (!scanOk || !connOk) {
        final permanent = (scan?.isPermanentlyDenied ?? false) ||
            (conn?.isPermanentlyDenied ?? false);
        _lastError = permanent
            ? 'Izin "Perangkat sekitar" (Bluetooth) ditolak permanen. Aktifkan lewat Pengaturan > Aplikasi > LoudSound > Izin.'
            : 'Izin "Perangkat sekitar" (Bluetooth) diperlukan untuk mencari perangkat IoT.';
        return false;
      }
    }

    return true;
  }

  /// Memastikan adapter Bluetooth menyala (Android akan menampilkan dialog sistem).
  Future<bool> _ensureBluetoothOn() async {
    try {
      var state = await FlutterBluePlus.adapterState
          .firstWhere((s) => s != BluetoothAdapterState.unknown)
          .timeout(const Duration(seconds: 3));
      if (state == BluetoothAdapterState.on) return true;

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          await FlutterBluePlus.turnOn();
        } catch (_) {}
        state = await FlutterBluePlus.adapterState
            .firstWhere((s) => s == BluetoothAdapterState.on)
            .timeout(const Duration(seconds: 6));
        return state == BluetoothAdapterState.on;
      }
    } catch (_) {}
    return false;
  }

  /// Memulai pemindaian perangkat BLE terdekat
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    _lastError = null;

    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      debugPrint('[BLE] Izin Bluetooth ditolak pengguna.');
      notifyListeners();
      return;
    }

    if (!await _ensureBluetoothOn()) {
      _lastError = 'Bluetooth belum aktif. Nyalakan Bluetooth lalu pindai ulang.';
      notifyListeners();
      return;
    }

    _discoveredDevices.clear();
    notifyListeners();

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final advName = r.advertisementData.advName;
        final platformName = r.device.platformName;
        final name = advName.isNotEmpty ? advName : platformName;

        final advertisesService = r.advertisementData.serviceUuids.any(
          (u) => u == BleUuids.serviceUuid || u == BleUuids.legacyServiceUuid,
        );
        final lowerName = name.toLowerCase();
        final isIot = advertisesService ||
            lowerName.contains('noise_monitor') ||
            lowerName.contains('loudsound');

        // Sembunyikan perangkat BLE anonim di sekitar kecuali itu perangkat IoT kita.
        if (name.isEmpty && !isIot) continue;

        final item = DiscoveredIotDevice(
          device: r.device,
          name: name.isEmpty ? 'Perangkat Tanpa Nama' : name,
          rssi: r.rssi,
          isLikelyIot: isIot,
        );

        final existingIdx = _discoveredDevices.indexWhere(
          (d) => d.device.remoteId == r.device.remoteId,
        );
        if (existingIdx >= 0) {
          _discoveredDevices[existingIdx] = item;
        } else {
          _discoveredDevices.add(item);
        }
      }

      // Perangkat IoT di atas, lalu urut sinyal terkuat.
      _discoveredDevices.sort((a, b) {
        if (a.isLikelyIot != b.isLikelyIot) return a.isLikelyIot ? -1 : 1;
        return b.rssi.compareTo(a.rssi);
      });
      notifyListeners();
    });

    _isScanningSub?.cancel();
    _isScanningSub = FlutterBluePlus.isScanning.listen((scanning) {
      _isScanning = scanning;
      notifyListeners();
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: timeout,
        // Tidak memakai lokasi: BLUETOOTH_SCAN dideklarasikan neverForLocation.
        androidUsesFineLocation: false,
      );
    } catch (e) {
      debugPrint('[BLE] Gagal startScan: $e');
      _lastError = 'Gagal memindai perangkat: $e';
      _isScanning = false;
      notifyListeners();
    }
  }

  /// Menghentikan pemindaian BLE
  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _isScanning = false;
    notifyListeners();
  }

  /// Menghubungkan ke perangkat IoT BLE
  Future<bool> connectToDevice(BluetoothDevice device) async {
    await stopScan();
    _lastError = null;

    _connectionState = BleDeviceConnectionState.connecting;
    _connectedDevice = device;
    notifyListeners();

    try {
      _deviceConnSub?.cancel();
      _deviceConnSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected &&
            _connectionState != BleDeviceConnectionState.connecting) {
          _connectionState = BleDeviceConnectionState.disconnected;
          _cleanupCharacteristics();
          notifyListeners();
        }
      });

      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
        // Minta MTU besar (Android) agar payload JSON tidak terpotong.
        mtu: 247,
      );

      // Temukan Service dan Characteristic SEBELUM dianggap "terhubung"
      // supaya UI tidak menampilkan "Menunggu data" tanpa langganan notifikasi.
      await _discoverServices(device);

      _connectionState = BleDeviceConnectionState.connected;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[BLE] Gagal terhubung ke device: $e');
      _lastError = 'Gagal terhubung: $e';
      _connectionState = BleDeviceConnectionState.disconnected;
      _cleanupCharacteristics();
      try {
        await device.disconnect();
      } catch (_) {}
      notifyListeners();
      return false;
    }
  }

  /// Menemukan GATT Services & Characteristics IoT
  Future<void> _discoverServices(BluetoothDevice device) async {
    _cleanupCharacteristics();

    final services = await device.discoverServices();

    BluetoothCharacteristic? telemetry;
    BluetoothCharacteristic? wifiConfig;
    BluetoothCharacteristic? wifiStatus;
    BluetoothCharacteristic? telemetryFallback;
    BluetoothCharacteristic? wifiConfigFallback;

    for (final service in services) {
      // Abaikan service GATT bawaan Android (Generic Access/Attribute, dsb.)
      final isGenericService = service.uuid.str128.startsWith('00001800') ||
          service.uuid.str128.startsWith('00001801');
      if (isGenericService) continue;

      for (final char in service.characteristics) {
        final props = char.properties;
        final uuid = char.uuid;

        if (uuid == BleUuids.wifiStatusCharacteristicUuid ||
            uuid == BleUuids.legacyWifiStatusCharacteristicUuid) {
          wifiStatus ??= char;
        } else if (uuid == BleUuids.wifiConfigCharacteristicUuid) {
          wifiConfig ??= char;
        } else if ((uuid == BleUuids.decibelCharacteristicUuid ||
                uuid == BleUuids.altDecibelCharacteristicUuid) &&
            (props.notify || props.indicate)) {
          telemetry ??= char;
        } else if (props.notify || props.indicate) {
          telemetryFallback ??= char;
        } else if (props.write || props.writeWithoutResponse) {
          wifiConfigFallback ??= char;
        }
      }
    }

    _decibelChar = telemetry ?? telemetryFallback;
    _wifiConfigChar = wifiConfig ?? wifiConfigFallback;
    _wifiStatusChar = wifiStatus;

    if (_decibelChar != null) {
      await _subscribeToDecibels(device, _decibelChar!);
    } else {
      debugPrint('[BLE] Characteristic telemetri suara tidak ditemukan');
    }
    if (_wifiStatusChar != null) {
      await _subscribeToWifiStatus(device, _wifiStatusChar!);
    }

    notifyListeners();
  }

  Future<void> _subscribeToWifiStatus(
    BluetoothDevice device,
    BluetoothCharacteristic char,
  ) async {
    try {
      _wifiStatusSub?.cancel();
      _wifiStatusSub = char.onValueReceived.listen(_handleWifiStatusBytes);
      device.cancelWhenDisconnected(_wifiStatusSub!);

      await char.setNotifyValue(true);

      // Baca status awal supaya UI langsung sinkron
      if (char.properties.read) {
        _handleWifiStatusBytes(await char.read());
      }
    } catch (e) {
      debugPrint('[BLE] Gagal subscribe ke Wi-Fi status: $e');
    }
  }

  void _handleWifiStatusBytes(List<int> data) {
    final statusText = utf8.decode(data, allowMalformed: true).trim();
    if (statusText.isNotEmpty) {
      _iotWifiStatus = statusText;
      notifyListeners();
    }
  }

  Future<void> _subscribeToDecibels(
    BluetoothDevice device,
    BluetoothCharacteristic char,
  ) async {
    try {
      _decibelSub?.cancel();
      _decibelSub = char.onValueReceived.listen(_handleTelemetryBytes);
      device.cancelWhenDisconnected(_decibelSub!);

      await char.setNotifyValue(true);

      // Baca nilai awal agar tampilan tidak menunggu notifikasi pertama
      if (char.properties.read) {
        _handleTelemetryBytes(await char.read());
      }
    } catch (e) {
      debugPrint('[BLE] Gagal subscribe ke telemetri suara: $e');
    }
  }

  void _handleTelemetryBytes(List<int> data) {
    if (data.isEmpty) return;
    final sample = parseTelemetry(utf8.decode(data, allowMalformed: true));
    if (sample == null) return;
    _applySample(sample);
  }

  /// Mengirim kredensial Wi-Fi ke perangkat IoT via BLE
  Future<bool> sendWifiCredentials({
    required String ssid,
    required String password,
  }) async {
    if (_connectionState != BleDeviceConnectionState.connected ||
        _connectedDevice == null) {
      _lastError = 'Perangkat belum terhubung';
      return false;
    }

    final char = _wifiConfigChar;
    if (char == null) {
      _lastError =
          'Firmware perangkat belum mendukung pengaturan Wi-Fi. Flash ulang DETEKSI_KEBISINGAN_IOT.ino versi terbaru.';
      return false;
    }

    try {
      final payload = jsonEncode({
        'ssid': ssid,
        'password': password,
      });

      final bytes = utf8.encode(payload);
      final useResponse = char.properties.write;
      await char.write(
        bytes,
        withoutResponse: !useResponse,
        // Mengizinkan data > MTU (SSID + password panjang)
        allowLongWrite: useResponse,
      );

      _connectedWifiSsid = ssid;
      _iotWifiStatus = 'Menghubungkan ke $ssid...';
      _lastError = null;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[BLE] Gagal mengirim kredensial Wi-Fi: $e');
      _lastError = 'Gagal mengirim kredensial Wi-Fi: $e';
      return false;
    }
  }

  /// Memutuskan koneksi BLE
  Future<void> disconnect() async {
    _mockSensorTimer?.cancel();
    _mockSensorTimer = null;
    _isMockDevice = false;
    _mockDeviceName = null;

    // Reset state SECARA SINKRON sebelum await, agar tidak menimpa koneksi baru
    // (mis. connectDemoDevice() yang memanggil disconnect() lalu langsung set state).
    final device = _connectedDevice;
    _connectedDevice = null;
    _connectionState = BleDeviceConnectionState.disconnected;
    _cleanupCharacteristics();
    notifyListeners();

    try {
      await device?.disconnect();
    } catch (_) {}
  }

  void _cleanupCharacteristics() {
    _wifiStatusSub?.cancel();
    _decibelSub?.cancel();
    _wifiStatusSub = null;
    _decibelSub = null;
    _wifiConfigChar = null;
    _wifiStatusChar = null;
    _decibelChar = null;
    _latestDecibels = null;
    _latestRms = null;
    _latestStatus = null;
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _isScanningSub?.cancel();
    _deviceConnSub?.cancel();
    _cleanupCharacteristics();
    super.dispose();
  }
}
