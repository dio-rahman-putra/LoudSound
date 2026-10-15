import 'package:flutter_test/flutter_test.dart';
import 'package:iot_loud_sound/ble_iot_service.dart';

void main() {
  group('BleIotService.parseTelemetry', () {
    test('JSON baru: db terkalibrasi dipakai apa adanya', () {
      final s = BleIotService.parseTelemetry(
        '{"db":74.3,"rms":0.01234,"status":"NORMAL"}',
      )!;
      expect(s.db, closeTo(74.3, 0.001));
      expect(s.status, 'NORMAL');
      // p = 10^((74.3 - 94) / 20) Pa
      expect(s.rms, closeTo(0.1035, 0.001));
    });

    test('payload terpotong 20 byte (MTU default) tetap terbaca', () {
      // Persis kasus bug: notifikasi terpotong di 20 byte -> jsonDecode gagal
      final truncated =
          '{"db":88.5,"rms":0.0123,"status":"TERLALU BERISIK"}'.substring(0, 20);
      final s = BleIotService.parseTelemetry(truncated)!;
      expect(s.db, closeTo(88.5, 0.001));
      // Status diturunkan dari ambang 85 dB karena field status terpotong
      expect(s.status, SoundCalibration.statusLoud);
    });

    test('firmware lama (rms skala /10000) dikonversi ke dB SPL', () {
      // 29.7284 = RMS pada 94 dB SPL
      final ref = BleIotService.parseTelemetry(
        '{"rms":29.7284,"status":"NORMAL"}',
      )!;
      expect(ref.db, closeTo(94.0, 0.01));

      // 10x lebih kecil = -20 dB
      final quiet = BleIotService.parseTelemetry('{"rms":2.97284}')!;
      expect(quiet.db, closeTo(74.0, 0.01));
    });

    test('db di-clamp ke rentang mikrofon 30..120 dB', () {
      expect(BleIotService.parseTelemetry('{"db":5.0}')!.db, 30.0);
      expect(BleIotService.parseTelemetry('{"db":150.0}')!.db, 120.0);
    });

    test('format DB:/RMS:/angka tunggal', () {
      expect(BleIotService.parseTelemetry('DB:68.5')!.db, closeTo(68.5, 0.001));
      expect(BleIotService.parseTelemetry('72.4')!.db, closeTo(72.4, 0.001));
      expect(
        BleIotService.parseTelemetry('RMS:29.7284')!.db,
        closeTo(94.0, 0.01),
      );
    });

    test('data tidak valid mengembalikan null', () {
      expect(BleIotService.parseTelemetry(''), isNull);
      expect(BleIotService.parseTelemetry('halo'), isNull);
      expect(BleIotService.parseTelemetry('{}'), isNull);
    });
  });

  group('SoundCalibration', () {
    test('94 dB SPL = 1 Pascal', () {
      expect(SoundCalibration.dbToPascal(94.0), closeTo(1.0, 1e-9));
      expect(SoundCalibration.dbToPascal(74.0), closeTo(0.1, 1e-9));
    });
  });
}
