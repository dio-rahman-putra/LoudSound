# LoudSound

Dashboard Flutter satu halaman untuk menampilkan tingkat suara dalam desibel
dan kategori kebisingan. Tampilan saat ini adalah UI awal; belum membaca
mikrofon atau terhubung ke perangkat IoT.

## Menjalankan aplikasi

```bash
flutter pub get
flutter run
```

## Menyiapkan notifikasi Firebase

Notifikasi push menggunakan Firebase Cloud Messaging (FCM) dan ditujukan untuk
Android/iOS. Kredensial Firebase tidak disertakan di project.

1. Buat project di [Firebase Console](https://console.firebase.google.com/) dan
   daftarkan aplikasi Android dengan application ID
   `com.example.iot_loud_sound`.
2. Pasang Firebase CLI dan FlutterFire CLI, lalu login:

   ```bash
   npm install -g firebase-tools
   firebase login
   dart pub global activate flutterfire_cli
   ```

3. Dari folder project jalankan:

   ```bash
   flutterfire configure
   ```

   Pilih project Firebase dan platform Android/iOS. Perintah ini akan mengisi
   `lib/firebase_options.dart`; ganti application ID di
   `android/app/build.gradle.kts` terlebih dahulu bila Anda memakai ID sendiri.
4. Untuk iOS, aktifkan Push Notifications dan Background Modes > Remote
   notifications di Xcode, lalu unggah APNs authentication key ke pengaturan
   Cloud Messaging di Firebase Console.
5. Jalankan aplikasi di perangkat Android/iOS, lalu tekan ikon lonceng dan
   izinkan notifikasi. Aplikasi akan berlangganan topic FCM `noise-alerts`.

Foreground notification Android ditampilkan melalui notification channel
`Peringatan kebisingan`. Untuk mengirim peringatan saat sensor mendeteksi suara
berisik, backend/IoT harus mengirim pesan FCM ke topic `noise-alerts` melalui
Firebase Admin SDK. Jangan menaruh service-account key di aplikasi Flutter.

## Titik integrasi IoT

Callback `onIoTDataReceived` di
`lib/main.dart` disiapkan sebagai titik masuk data sensor. Hubungkan callback
tersebut ke stream/peristiwa dari perangkat, lalu perbarui nilai desibel dan
pemetaan kategori `Pelan`, `Normal`, atau `Berisik` sesuai ambang yang
digunakan perangkat.
