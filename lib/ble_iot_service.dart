import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// UUID Service & Characteristic BLE standar untuk IoT LoudSound (ESP32 DETEKSI_KEBISINGAN_IOT.ino)
class BleUuids {
  // Service UUID utama dari DETEKSI_KEBISINGAN_IOT.ino
  static final Guid serviceUuid =
      Guid('4fa8c001-124e-423a-bc3f-923de9dc001e');

  // Service UUID legacy / cadangan
  static final Guid legacyServiceUuid =
      Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');

  // Characteristic UUID telemetri suara utama dari DETEKSI_KEBISINGAN_IOT.ino (Read/Notify)
  static final Guid decibelCharacteristicUuid =
      Guid('beb5483e-36e1-4688-b7f5-ea07361b26a8');

  // Characteristic UUID cadangan
  static final Guid altDecibelCharacteristicUuid =
      Guid('beb5483e-36e1-4688-b7f5-ea07361b26aa');

  // Characteristic untuk konfigurasi Wi-Fi jika didukung perangkat
  static final Guid wifiConfigCharacteristicUuid =
      Guid('beb5483e-36e1-4688-b7f5-ea07361b26a8');

  // Characteristic status Wi-Fi
  static final Guid wifiStatusCharacteristicUuid =
      Guid('beb5483e-36e1-4688-b7f5-ea07361b26a9');
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

  DiscoveredIotDevice({
    required this.device,
    required this.name,
    required this.rssi,
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

  String? _connectedWifiSsid;
  String? get connectedWifiSsid => _connectedWifiSsid;

  String _iotWifiStatus = 'Belum terhubung ke Wi-Fi';
  String get iotWifiStatus => _iotWifiStatus;

  double? _latestRms;
  double? get latestRms => _latestRms;

  double? _latestDecibels;
  double? get latestDecibels => _latestDecibels;

  String? _latestStatus;
  String? get latestStatus => _latestStatus;

  /// Konversi nilai RMS ke Desibel (dB)
  static double convertRmsToDb(double rms) {
    if (rms <= 0.00001) return 30.0;
    // Skala RMS dari DETEKSI_KEBISINGAN_IOT.ino (sekitar 30 - 150)
    // Nilai ini setara dengan intensitas kebisingan (Threshold Normal: 70, Loud: 120)
    if (rms >= 20.0) {
      return rms.clamp(30.0, 130.0);
    }
    // Jika data berupa tegangan volt mentah (< 3.3V)
    double vRms = rms;
    if (vRms > 3.3) {
      vRms = (vRms / 4095.0) * 3.3;
    }
    final db = 20.0 * (math.log(vRms / 0.00005) / math.ln10);
    return db.clamp(30.0, 130.0);
  }

  /// Konversi Desibel (dB) ke nilai RMS
  static double convertDbToRms(double db) {
    return db;
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

  /// Menghubungkan perangkat demo/simulasi sesuai konfigurasi DETEKSI_KEBISINGAN_IOT.ino
  void connectDemoDevice({String name = 'Noise_Monitor'}) {
    disconnect();
    _isMockDevice = true;
    _mockDeviceName = name;
    _connectionState = BleDeviceConnectionState.connected;
    _iotWifiStatus = 'BLE Terhubung (Sensor I2S Aktif)';
    _connectedWifiSsid = null;

    // Inisialisasi awal
    _latestDecibels = 68.4;
    _latestRms = 68.4;
    _latestStatus = 'NORMAL';
    _readingTick++;
    notifyListeners();

    _mockSensorTimer?.cancel();
    // Mensimulasikan ESP32 yang mengirim sampel data setiap 1000ms (INTERVAL = 1000 pada sketch)
    _mockSensorTimer =
        Timer.periodic(const Duration(milliseconds: 1000), (timer) {
      if (_connectionState != BleDeviceConnectionState.connected ||
          !_isMockDevice) {
        timer.cancel();
        return;
      }
      final tick = timer.tick;
      final base = 65.0 + math.sin(tick * 0.28) * 18.0;
      final noise = (math.Random().nextDouble() - 0.5) * 8.0;
      final spike = (tick % 12 == 0) ? 44.0 : 0.0;
      final rms = (base + noise + spike).clamp(32.0, 135.0);
      final isLoud = rms >= 120.0; // THRESHOLD_HIGH pada sketch ESP32

      _latestRms = double.parse(rms.toStringAsFixed(1));
      _latestDecibels = _latestRms;
      _latestStatus = isLoud ? 'TERLALU BERISIK' : 'NORMAL';
      _readingTick++;
      notifyListeners();
    });
  }

  /// Memperbarui nilai suara secara manual (berguna untuk testing/simulasi)
  void updateSoundData({double? rms, double? decibels, String? status}) {
    if (status != null) {
      _latestStatus = status;
    }
    if (rms != null) {
      _latestRms = rms;
      _latestDecibels = decibels ?? convertRmsToDb(rms);
    } else if (decibels != null) {
      _latestDecibels = decibels;
      _latestRms = convertDbToRms(decibels);
    }
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

  /// Meminta izin Bluetooth & Lokasi (wajib untuk Android 12+)
  Future<bool> requestPermissions() async {
    if (kIsWeb) return false;

    if (defaultTargetPlatform == TargetPlatform.android) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();

      final scanGranted = statuses[Permission.bluetoothScan]?.isGranted ?? true;
      final connGranted =
          statuses[Permission.bluetoothConnect]?.isGranted ?? true;
      final locGranted = statuses[Permission.location]?.isGranted ?? true;

      return (scanGranted && connGranted) || locGranted;
    }

    return true;
  }

  /// Memulai pemindaian perangkat BLE terdekat
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      debugPrint('[BLE] Izin Bluetooth ditolak pengguna.');
      return;
    }

    _discoveredDevices.clear();
    notifyListeners();

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : (r.device.platformName.isNotEmpty
                ? r.device.platformName
                : 'Perangkat Tanpa Nama');

        final existingIdx = _discoveredDevices.indexWhere(
          (d) => d.device.remoteId == r.device.remoteId,
        );

        if (existingIdx >= 0) {
          _discoveredDevices[existingIdx] = DiscoveredIotDevice(
            device: r.device,
            name: name,
            rssi: r.rssi,
          );
        } else {
          _discoveredDevices.add(
            DiscoveredIotDevice(
              device: r.device,
              name: name,
              rssi: r.rssi,
            ),
          );
        }
      }
      notifyListeners();
    });

    _isScanningSub?.cancel();
    _isScanningSub = FlutterBluePlus.isScanning.listen((scanning) {
      _isScanning = scanning;
      notifyListeners();
    });

    try {
      await FlutterBluePlus.startScan(timeout: timeout);
    } catch (e) {
      debugPrint('[BLE] Gagal startScan: $e');
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

    _connectionState = BleDeviceConnectionState.connecting;
    _connectedDevice = device;
    notifyListeners();

    try {
      _deviceConnSub?.cancel();
      _deviceConnSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.connected) {
          _connectionState = BleDeviceConnectionState.connected;
        } else if (state == BluetoothConnectionState.disconnected) {
          _connectionState = BleDeviceConnectionState.disconnected;
          _cleanupCharacteristics();
        }
        notifyListeners();
      });

      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      _connectionState = BleDeviceConnectionState.connected;
      notifyListeners();

      // Temukan Service dan Characteristic
      await _discoverServices(device);
      return true;
    } catch (e) {
      debugPrint('[BLE] Gagal terhubung ke device: $e');
      _connectionState = BleDeviceConnectionState.disconnected;
      _cleanupCharacteristics();
      notifyListeners();
      return false;
    }
  }

  /// Menemukan GATT Services & Characteristics IoT
  Future<void> _discoverServices(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      for (final service in services) {
        for (final char in service.characteristics) {
          // 1. Cek characteristic telemetri suara dari DETEKSI_KEBISINGAN_IOT.ino (beb5483e-36e1-4688-b7f5-ea07361b26a8)
          if (char.uuid == BleUuids.decibelCharacteristicUuid ||
              char.uuid == BleUuids.altDecibelCharacteristicUuid ||
              char.properties.notify) {
            _decibelChar = char;
            await _subscribeToDecibels(char);
          }

          // 2. Cek characteristic Wi-Fi config (jika perangkat mendukung penulisan kredensial)
          if (char.properties.write || char.properties.writeWithoutResponse) {
            _wifiConfigChar ??= char;
          }

          // 3. Cek characteristic status Wi-Fi
          if (char.uuid == BleUuids.wifiStatusCharacteristicUuid) {
            _wifiStatusChar = char;
            await _subscribeToWifiStatus(char);
          }
        }
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[BLE] Gagal discoverServices: $e');
    }
  }

  Future<void> _subscribeToWifiStatus(BluetoothCharacteristic char) async {
    try {
      await char.setNotifyValue(true);
      _wifiStatusSub?.cancel();
      _wifiStatusSub = char.onValueReceived.listen((data) {
        final statusText = utf8.decode(data, allowMalformed: true).trim();
        if (statusText.isNotEmpty) {
          _iotWifiStatus = statusText;
          notifyListeners();
        }
      });
    } catch (e) {
      debugPrint('[BLE] Gagal subscribe ke Wi-Fi status: $e');
    }
  }

  Future<void> _subscribeToDecibels(BluetoothCharacteristic char) async {
    try {
      await char.setNotifyValue(true);
      _decibelSub?.cancel();
      _decibelSub = char.onValueReceived.listen((data) {
        final text = utf8.decode(data, allowMalformed: true).trim();
        if (text.isEmpty) return;

        double? parsedRms;
        double? parsedDb;
        String? parsedStatus;

        // 1. Coba parse format JSON dari DETEKSI_KEBISINGAN_IOT.ino: {"rms": 74.2, "status": "NORMAL"}
        if (text.startsWith('{') && text.endsWith('}')) {
          try {
            final json = jsonDecode(text) as Map<String, dynamic>;
            if (json.containsKey('rms')) {
              parsedRms = (json['rms'] as num).toDouble();
            }
            if (json.containsKey('db')) {
              parsedDb = (json['db'] as num).toDouble();
            }
            if (json.containsKey('status')) {
              parsedStatus = json['status']?.toString();
            }
          } catch (_) {}
        }

        // 2. Cek format key-value, misal "RMS:74.2" atau "DB:68.5"
        if (parsedRms == null && text.toUpperCase().startsWith('RMS:')) {
          parsedRms = double.tryParse(text.substring(4).trim());
        } else if (parsedDb == null && text.toUpperCase().startsWith('DB:')) {
          parsedDb = double.tryParse(text.substring(3).trim());
        }

        // 3. Format angka mentah tunggal
        if (parsedRms == null && parsedDb == null) {
          final singleNum = double.tryParse(text);
          if (singleNum != null) {
            parsedRms = singleNum;
          }
        }

        if (parsedRms != null || parsedDb != null) {
          updateSoundData(
            rms: parsedRms,
            decibels: parsedDb,
            status: parsedStatus,
          );
        }
      });
    } catch (e) {
      debugPrint('[BLE] Gagal subscribe ke telemetri suara: $e');
    }
  }

  /// Mengirim kredensial Wi-Fi ke perangkat IoT via BLE
  Future<bool> sendWifiCredentials({
    required String ssid,
    required String password,
  }) async {
    if (_connectionState != BleDeviceConnectionState.connected ||
        _connectedDevice == null) {
      debugPrint('[BLE] Perangkat belum terhubung');
      return false;
    }

    if (_wifiConfigChar == null) {
      debugPrint('[BLE] Characteristic konfigurasi Wi-Fi tidak ditemukan');
      return false;
    }

    try {
      final payload = jsonEncode({
        'ssid': ssid,
        'password': password,
      });

      final bytes = utf8.encode(payload);
      await _wifiConfigChar!.write(
        bytes,
        withoutResponse: !_wifiConfigChar!.properties.write,
      );

      _connectedWifiSsid = ssid;
      _iotWifiStatus = 'Menghubungkan ke $ssid...';
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[BLE] Gagal mengirim kredensial Wi-Fi: $e');
      return false;
    }
  }

  /// Memutuskan koneksi BLE
  Future<void> disconnect() async {
    _mockSensorTimer?.cancel();
    _mockSensorTimer = null;
    _isMockDevice = false;
    _mockDeviceName = null;
    try {
      await _connectedDevice?.disconnect();
    } catch (_) {}
    _connectedDevice = null;
    _connectionState = BleDeviceConnectionState.disconnected;
    _cleanupCharacteristics();
    notifyListeners();
  }

  void _cleanupCharacteristics() {
    _wifiStatusSub?.cancel();
    _decibelSub?.cancel();
    _wifiConfigChar = null;
    _wifiStatusChar = null;
    _decibelChar = null;
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
