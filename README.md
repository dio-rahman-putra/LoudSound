# LoudSound

Dashboard Flutter satu halaman untuk menampilkan tingkat suara (dB SPL)
realtime dari perangkat IoT ESP32 (mikrofon INMP441) melalui Bluetooth LE.

## Menjalankan aplikasi

```bash
flutter pub get
flutter run
```

## Notifikasi kebisingan

Tekan ikon lonceng di aplikasi untuk mengaktifkan notifikasi. Aplikasi membuat
notifikasi **lokal** begitu data BLE menunjukkan suara melewati 85 dB (diulang
tiap 30 detik selama masih berisik). Fitur ini tidak memerlukan Firebase. Untuk
Android 13+ izin notifikasi akan diminta saat lonceng ditekan.

Notifikasi berjalan selama aplikasi masih hidup (foreground/background).
Untuk notifikasi saat aplikasi benar-benar tertutup diperlukan backend FCM.

## Izin Android

- Android 12+: hanya "Perangkat sekitar" (Bluetooth scan/connect + Wi-Fi).
  Lokasi/GPS **tidak** diperlukan (`neverForLocation`).
- Android 11 ke bawah: sistem Android mewajibkan izin lokasi untuk scan BLE.

## Protokol BLE (DETEKSI_KEBISINGAN_IOT.ino)

Service `4fa8c001-124e-423a-bc3f-923de9dc001e`:

| Characteristic | UUID (akhiran) | Sifat | Isi |
| --- | --- | --- | --- |
| Telemetri | `...26a8` | Read/Notify | `{"db":74.3,"rms":0.01234,"status":"NORMAL"}` |
| Konfigurasi Wi-Fi | `...26b1` | Write | `{"ssid":"...","password":"..."}` |
| Status Wi-Fi | `...26b2` | Read/Notify | teks status koneksi |

- `db` = dB SPL terkalibrasi (INMP441: -26 dBFS @ 94 dB SPL), `rms` = tekanan
  suara dalam Pascal.
- Telemetri dikirim tiap 250 ms (realtime). Alarm/buzzer/Serial tetap dievaluasi
  tiap 2 detik di alat.
- Kalibrasi manual: atur `CAL_OFFSET_DB` di firmware dengan membandingkan ke
  sound level meter referensi.
- Firmware memanggil `BLEDevice::setMTU(247)`; tanpa itu payload terpotong 20
  byte dan data tidak terbaca di aplikasi.
