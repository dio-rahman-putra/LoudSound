#include <Arduino.h>
#include <driver/i2s.h>
#include <math.h>
#include <WiFi.h>

// Library khusus BLE
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// =====================================
// KONFIGURASI BLE (UUID)
// =====================================
// UUID HARUS sama dengan lib/ble_iot_service.dart
#define DEVICE_NAME             "Noise_Monitor"
#define SERVICE_UUID            "4fa8c001-124e-423a-bc3f-923de9dc001e"
#define CHARACTERISTIC_UUID     "beb5483e-36e1-4688-b7f5-ea07361b26a8"  // Telemetri suara (Read/Notify)
#define CHAR_WIFI_CONFIG_UUID   "beb5483e-36e1-4688-b7f5-ea07361b26b1"  // Kredensial Wi-Fi dari app (Write)
#define CHAR_WIFI_STATUS_UUID   "beb5483e-36e1-4688-b7f5-ea07361b26b2"  // Status Wi-Fi ke app (Read/Notify)

// MTU diperbesar supaya payload JSON (~45 byte) & kredensial Wi-Fi tidak terpotong.
// (MTU default ESP32 = 23 -> payload hanya 20 byte -> data tidak terbaca di app)
#define BLE_MTU 247

BLECharacteristic *pCharacteristic = nullptr;
BLECharacteristic *pWifiStatusChar = nullptr;
volatile bool deviceConnected = false;

// Callback untuk mendeteksi koneksi BLE
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) override {
      deviceConnected = true;
      Serial.println("Klien BLE Terhubung!");
    }

    void onDisconnect(BLEServer* pServer) override {
      deviceConnected = false;
      Serial.println("Klien BLE Terputus. Memulai advertising ulang...");
      // Mulai memancar lagi agar HP bisa menemukan dan terhubung kembali
      pServer->getAdvertising()->start();
    }
};

// =====================================
// KONFIGURASI PIN 
// =====================================
#define I2S_PORT I2S_NUM_0
#define I2S_WS   25
#define I2S_SCK  26
#define I2S_SD   33

#define BUZZER_PIN 27

// =====================================
// KONFIGURASI AUDIO, KALIBRASI & HISTERESIS
// =====================================
#define SAMPLE_RATE  16000
#define SAMPLE_COUNT 1024      // 1 blok = 1024 sampel = 64 ms

int32_t samples[SAMPLE_COUNT];

// --- Kalibrasi mikrofon INMP441 -> dB SPL ---
// Datasheet INMP441: sensitivitas -26 dBFS pada 94 dB SPL (tone 1 kHz).
// Data I2S = 24-bit signed. Amplitudo RMS sinus full-scale = 2^23 / sqrt(2).
// Referensi RMS pada 94 dB SPL = 10^(-26/20) * 2^23 / sqrt(2) = ~297284 (count).
//   dB SPL = 94 + 20 * log10(rms / MIC_REF_RMS) + CAL_OFFSET_DB
const double MIC_REF_DB   = 94.0;
const double MIC_REF_RMS  = 297284.0;
// Offset kalibrasi manual: bandingkan dengan sound level meter / aplikasi
// referensi, lalu isi selisihnya di sini (mis. -3.0 jika alat terbaca 3 dB lebih tinggi).
const double CAL_OFFSET_DB = 0.0;
const double DB_MIN = 30.0;    // noise floor INMP441 (~29 dB SPL)
const double DB_MAX = 120.0;   // acoustic overload point INMP441 (~120 dB SPL)

// --- Ambang alarm (dalam dB SPL, sama dengan NoiseLevel di aplikasi: >85 dB = Berisik) ---
const double THRESHOLD_HIGH_DB = 85.0;
const double THRESHOLD_LOW_DB  = 75.0;   // histeresis: alarm mati jika < 75 dB

bool isLoud = false;

// --- Interval ---
// Evaluasi alarm/buzzer/Serial TETAP 2 detik (rata-rata RMS 2 detik).
const unsigned long ALARM_INTERVAL_MS = 2000;
// Telemetri BLE ke aplikasi dikirim lebih sering agar tampilan mobile realtime.
const unsigned long TELEMETRY_INTERVAL_MS = 250;

// Akumulator energi (jumlah kuadrat) untuk jendela cepat (BLE) dan jendela alarm (2 detik)
double sumSqFast = 0;
unsigned long cntFast = 0;
double sumSqAlarm = 0;
unsigned long cntAlarm = 0;

unsigned long lastTelemetryMillis = 0;
unsigned long lastAlarmMillis = 0;

double rmsToDb(double rms) {
  if (rms <= 0.0) return DB_MIN;
  double db = MIC_REF_DB + 20.0 * log10(rms / MIC_REF_RMS) + CAL_OFFSET_DB;
  if (db < DB_MIN) db = DB_MIN;
  if (db > DB_MAX) db = DB_MAX;
  return db;
}

// =====================================
// WI-FI PROVISIONING (via BLE, non-blocking)
// =====================================
enum WifiProvState { WS_IDLE, WS_CONNECTING, WS_CONNECTED };

WifiProvState wifiState = WS_IDLE;
volatile bool wifiRequestPending = false;
String pendingSsid = "";
String pendingPassword = "";
String activeSsid = "";
unsigned long wifiConnectStart = 0;
const unsigned long WIFI_CONNECT_TIMEOUT_MS = 20000;

void updateWifiStatus(const String &status) {
  Serial.println("[Wi-Fi] " + status);
  if (pWifiStatusChar != nullptr) {
    pWifiStatusChar->setValue((uint8_t*)status.c_str(), status.length());
    if (deviceConnected) pWifiStatusChar->notify();
  }
}

// Ambil nilai string dari JSON sederhana, mendukung escape \" dan \\ pada password.
String extractJsonString(const String &json, const char *key) {
  String needle = String("\"") + key + "\"";
  int k = json.indexOf(needle);
  if (k < 0) return "";
  int colon = json.indexOf(':', k + needle.length());
  if (colon < 0) return "";
  int q = json.indexOf('"', colon + 1);
  if (q < 0) return "";

  String out = "";
  for (int i = q + 1; i < (int)json.length(); i++) {
    char c = json[i];
    if (c == '\\' && i + 1 < (int)json.length()) {
      char n = json[++i];
      if (n == 'n') out += '\n';
      else if (n == 't') out += '\t';
      else out += n;
    } else if (c == '"') {
      return out;
    } else {
      out += c;
    }
  }
  return out;
}

// Callback saat aplikasi menulis kredensial Wi-Fi: {"ssid":"...","password":"..."}
class WifiConfigCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pChar) override {
      auto raw = pChar->getValue();           // std::string (core 2.x) / String (core 3.x)
      String rx = String(raw.c_str());
      if (rx.length() == 0) return;

      String ssid = extractJsonString(rx, "ssid");
      String pass = extractJsonString(rx, "password");

      if (ssid.length() == 0) {
        Serial.println("[BLE] Data Wi-Fi tidak valid (SSID kosong)");
        return;
      }

      Serial.println("[BLE] Kredensial Wi-Fi diterima untuk SSID: " + ssid);
      pendingSsid = ssid;
      pendingPassword = pass;
      wifiRequestPending = true;   // diproses di loop() agar callback BLE tidak terblokir
    }
};

void handleWifi() {
  if (wifiRequestPending) {
    wifiRequestPending = false;
    activeSsid = pendingSsid;

    WiFi.disconnect(true);
    WiFi.mode(WIFI_STA);
    WiFi.begin(activeSsid.c_str(), pendingPassword.c_str());

    wifiState = WS_CONNECTING;
    wifiConnectStart = millis();
    updateWifiStatus("Menghubungkan ke " + activeSsid + "...");
    return;
  }

  if (wifiState == WS_CONNECTING) {
    if (WiFi.status() == WL_CONNECTED) {
      wifiState = WS_CONNECTED;
      updateWifiStatus("Tersambung (IP: " + WiFi.localIP().toString() + ")");
    } else if (millis() - wifiConnectStart >= WIFI_CONNECT_TIMEOUT_MS) {
      wifiState = WS_IDLE;
      WiFi.disconnect(true);
      updateWifiStatus("Gagal terhubung ke " + activeSsid + " (cek SSID/password)");
    }
  } else if (wifiState == WS_CONNECTED && WiFi.status() != WL_CONNECTED) {
    wifiState = WS_CONNECTING;
    wifiConnectStart = millis();
    updateWifiStatus("Wi-Fi terputus, menyambung ulang ke " + activeSsid + "...");
  }
}

// =====================================
// INISIALISASI I2S
// =====================================
bool setupI2S() {
  i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = 256,
    .use_apll = false,
    .tx_desc_auto_clear = false,
    .fixed_mclk = 0
  };

  i2s_pin_config_t pin_config = {
    .bck_io_num = I2S_SCK,
    .ws_io_num = I2S_WS,
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num = I2S_SD
  };

  if (i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL) != ESP_OK) return false;
  if (i2s_set_pin(I2S_PORT, &pin_config) != ESP_OK) {
    i2s_driver_uninstall(I2S_PORT);
    return false;
  }

  i2s_zero_dma_buffer(I2S_PORT);
  return true;
}
  
// =====================================
// BUZZER 3 KALI BUNYI (NON-BLOCKING)
// =====================================
// Tidak memakai delay() agar pembacaan mikrofon & pengiriman BLE tidak tertahan.
int buzzerStep = 0;                 // 0 = idle, 1..6 = urutan ON/OFF
unsigned long buzzerStepAt = 0;
const unsigned long BUZZER_STEP_MS = 150;

void triggerBuzzerAlert() {
  if (buzzerStep != 0) return;      // sedang bunyi
  buzzerStep = 1;
  buzzerStepAt = millis();
  digitalWrite(BUZZER_PIN, HIGH);
}

void updateBuzzer() {
  if (buzzerStep == 0) return;
  if (millis() - buzzerStepAt < BUZZER_STEP_MS) return;

  buzzerStepAt = millis();
  buzzerStep++;
  if (buzzerStep > 6) {
    digitalWrite(BUZZER_PIN, LOW);
    buzzerStep = 0;
    return;
  }
  digitalWrite(BUZZER_PIN, (buzzerStep % 2 == 1) ? HIGH : LOW);
}

// =====================================
// KIRIM TELEMETRI VIA BLE
// =====================================
// Format: {"db":74.3,"rms":0.01234,"status":"NORMAL"}
//   db   = dB SPL terkalibrasi
//   rms  = tekanan suara RMS dalam Pascal (p = 10^((dB-94)/20))
// "db" sengaja di depan agar tetap terbaca bila payload terpotong.
void sendTelemetry(double db) {
  if (!deviceConnected || pCharacteristic == nullptr) return;

  double pascal = pow(10.0, (db - MIC_REF_DB) / 20.0);
  char jsonBuffer[96];
  int len = snprintf(jsonBuffer, sizeof(jsonBuffer),
                     "{\"db\":%.1f,\"rms\":%.5f,\"status\":\"%s\"}",
                     db, pascal, isLoud ? "TERLALU BERISIK" : "NORMAL");
  if (len <= 0) return;

  pCharacteristic->setValue((uint8_t*)jsonBuffer, (size_t)len);
  pCharacteristic->notify();
}

// =====================================
// SETUP
// =====================================
void setup() {
  Serial.begin(115200);
  delay(1000);

  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);

  Serial.println("\n=================");
  Serial.println(" DETEKSI KEBISINGAN + BLE");
  Serial.println("===================");

  // Inisialisasi Perangkat BLE
  BLEDevice::init(DEVICE_NAME);
  BLEDevice::setMTU(BLE_MTU);
  BLEServer *pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  // Buat BLE Service
  BLEService *pService = pServer->createService(SERVICE_UUID);

  // 1. Telemetri suara (READ + NOTIFY)
  pCharacteristic = pService->createCharacteristic(
                      CHARACTERISTIC_UUID,
                      BLECharacteristic::PROPERTY_READ   |
                      BLECharacteristic::PROPERTY_NOTIFY
                    );
  pCharacteristic->addDescriptor(new BLE2902());
  pCharacteristic->setValue("{\"db\":0.0,\"rms\":0.0,\"status\":\"NORMAL\"}");

  // 2. Konfigurasi Wi-Fi dari aplikasi (WRITE)
  BLECharacteristic *pWifiConfigChar = pService->createCharacteristic(
                      CHAR_WIFI_CONFIG_UUID,
                      BLECharacteristic::PROPERTY_WRITE |
                      BLECharacteristic::PROPERTY_WRITE_NR
                    );
  pWifiConfigChar->setCallbacks(new WifiConfigCallbacks());

  // 3. Status Wi-Fi ke aplikasi (READ + NOTIFY)
  pWifiStatusChar = pService->createCharacteristic(
                      CHAR_WIFI_STATUS_UUID,
                      BLECharacteristic::PROPERTY_READ   |
                      BLECharacteristic::PROPERTY_NOTIFY
                    );
  pWifiStatusChar->addDescriptor(new BLE2902());
  pWifiStatusChar->setValue("Belum terhubung ke Wi-Fi");

  // Jalankan Service
  pService->start();

  // Mulai Advertising BLE
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06); // Fungsi kompatibilitas iOS
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("BLE Siap! Silakan hubungkan dari aplikasi mobile.");

  if (!setupI2S()) {
    Serial.println("ERROR: Inisialisasi I2S Gagal!");
    while (true) { delay(1000); }
  }

  lastTelemetryMillis = millis();
  lastAlarmMillis = millis();
}

// =====================================
// LOOP
// =====================================
void loop() {
  updateBuzzer();
  handleWifi();

  size_t bytes_read = 0;
  esp_err_t err = i2s_read(I2S_PORT, samples, sizeof(samples), &bytes_read, portMAX_DELAY);

  if (err != ESP_OK || bytes_read == 0) return;

  int count = bytes_read / sizeof(int32_t);

  // Sampel 24-bit (data I2S INMP441 left-justified di 32-bit)
  // Hilangkan DC offset mikrofon per blok agar tidak mengganggu hitungan RMS.
  double mean = 0.0;
  for (int i = 0; i < count; i++) {
    mean += (double)(samples[i] >> 8);
  }
  mean /= count;

  double sum_squares = 0.0;
  for (int i = 0; i < count; i++) {
    double v = (double)(samples[i] >> 8) - mean;
    sum_squares += v * v;
  }

  sumSqFast += sum_squares;
  cntFast += count;
  sumSqAlarm += sum_squares;
  cntAlarm += count;

  unsigned long currentMillis = millis();

  // ---- Telemetri BLE realtime (rata-rata RMS jendela ~250 ms) ----
  if (currentMillis - lastTelemetryMillis >= TELEMETRY_INTERVAL_MS) {
    lastTelemetryMillis = currentMillis;

    if (cntFast > 0) {
      double dbFast = rmsToDb(sqrt(sumSqFast / cntFast));
      sendTelemetry(dbFast);
    }
    sumSqFast = 0;
    cntFast = 0;
  }

  // ---- Evaluasi alarm + Serial setiap 2 detik ----
  if (currentMillis - lastAlarmMillis >= ALARM_INTERVAL_MS) {
    lastAlarmMillis = currentMillis;

    double rmsAvg = (cntAlarm > 0) ? sqrt(sumSqAlarm / cntAlarm) : 0.0;
    double dbAvg = rmsToDb(rmsAvg);

    // Logika Histeresis
    if (!isLoud && dbAvg >= THRESHOLD_HIGH_DB) {
      isLoud = true;
    } else if (isLoud && dbAvg < THRESHOLD_LOW_DB) {
      isLoud = false;
    }

    // Jika status berisik, bunyikan buzzer (non-blocking)
    if (isLoud) {
      triggerBuzzerAlert();
    }

    // Tampilkan di Serial Monitor Laptop
    Serial.printf("dB: %5.1f | RMS: %.0f | Status: %s\n",
                  dbAvg, rmsAvg, isLoud ? "TERLALU BERISIK" : "NORMAL");

    // Reset Akumulator alarm
    sumSqAlarm = 0;
    cntAlarm = 0;
  }
}