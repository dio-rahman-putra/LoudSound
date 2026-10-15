/*
 * LoudSound ESP32 Firmware: BLE Pairing, Wi-Fi Provisioning & Sound Sensor Telemetry
 * 
 * Fitur:
 * 1. Mengiklankan BLE dengan nama "LoudSound-ESP32"
 * 2. Menerima konfigurasi Wi-Fi (SSID & Password) dari aplikasi Flutter melalui BLE
 * 3. Menghubungkan ESP32 ke jaringan Wi-Fi lokal
 * 4. Membaca sensor suara (Analog Pin 34 atau microphone KY-038 / MAX4466)
 * 5. Mengirimkan nilai desibel real-time ke aplikasi melalui BLE & Serial Monitor
 */

#include <WiFi.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// UUID harus sama persis dengan yang ada di lib/ble_iot_service.dart
#define SERVICE_UUID           "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_WIFI_CONFIG_UUID  "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define CHAR_WIFI_STATUS_UUID  "beb5483e-36e1-4688-b7f5-ea07361b26a9"
#define CHAR_DECIBEL_UUID      "beb5483e-36e1-4688-b7f5-ea07361b26aa"

#define SOUND_SENSOR_PIN       34 // Pin analog ESP32 untuk sensor suara

BLEServer* pServer = NULL;
BLECharacteristic* pWifiConfigChar = NULL;
BLECharacteristic* pWifiStatusChar = NULL;
BLECharacteristic* pDecibelChar = NULL;

bool deviceConnected = false;
bool oldDeviceConnected = false;
String targetSsid = "";
String targetPassword = "";
bool newWifiReceived = false;

// Callback koneksi BLE
class ServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("[BLE] Aplikasi mobile terhubung!");
  };

  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("[BLE] Aplikasi mobile terputus.");
  }
};

// Callback saat aplikasi menulis kredensial Wi-Fi ke characteristic
class WifiConfigCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    String rxValue = pCharacteristic->getValue();
    if (rxValue.length() > 0) {
      Serial.print("[BLE] Data Wi-Fi diterima: ");
      Serial.println(rxValue);

      // Parsing JSON sederhana: {"ssid":"...","password":"..."}
      int ssidKey = rxValue.indexOf("\"ssid\"");
      int passKey = rxValue.indexOf("\"password\"");

      if (ssidKey != -1 && passKey != -1) {
        int ssidStart = rxValue.indexOf("\"", ssidKey + 6) + 1;
        int ssidEnd = rxValue.indexOf("\"", ssidStart);
        int passStart = rxValue.indexOf("\"", passKey + 10) + 1;
        int passEnd = rxValue.indexOf("\"", passStart);

        if (ssidStart > 0 && ssidEnd > ssidStart) {
          targetSsid = rxValue.substring(ssidStart, ssidEnd);
          targetPassword = (passStart > 0 && passEnd > passStart) ? rxValue.substring(passStart, passEnd) : "";
          newWifiReceived = true;
        }
      }
    }
  }
};

void updateWifiStatus(String status) {
  if (pWifiStatusChar != NULL) {
    pWifiStatusChar->setValue(status.c_str());
    pWifiStatusChar->notify();
  }
  Serial.println("[Wi-Fi Status] " + status);
}

void connectToWifi(String ssid, String password) {
  updateWifiStatus("Menghubungkan ke " + ssid + "...");
  WiFi.disconnect(true);
  delay(500);
  WiFi.begin(ssid.c_str(), password.c_str());

  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 25) {
    delay(500);
    Serial.print(".");
    attempts++;
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    String ipStr = WiFi.localIP().toString();
    updateWifiStatus("Tersambung (IP: " + ipStr + ")");
    Serial.println("[Wi-Fi] Berhasil terhubung! IP: " + ipStr);
  } else {
    updateWifiStatus("Gagal terhubung ke " + ssid);
    Serial.println("[Wi-Fi] Gagal terhubung.");
  }
}

// Pembacaan True RMS (Root Mean Square) dan kalkulasi Desibel dari sensor suara
void readSoundMetrics(float &rmsOut, float &dbOut) {
  const int sampleWindow = 40; // Sampling window 40 ms
  unsigned long startMillis = millis();
  
  float sumSquaredDiff = 0.0;
  int sampleCount = 0;
  
  // Baca DC bias awal (biasanya ~1.65V pada sensor analog audio ber-offset DC)
  const float V_BIAS = 1.65; // Volt (setengah dari 3.3V)
  
  while (millis() - startMillis < sampleWindow) {
    int raw = analogRead(SOUND_SENSOR_PIN);
    float volt = (raw / 4095.0) * 3.3; // Konversi ADC 12-bit ESP32 ke Volt
    float diff = volt - V_BIAS;
    sumSquaredDiff += (diff * diff);
    sampleCount++;
    delayMicroseconds(100);
  }
  
  if (sampleCount > 0) {
    rmsOut = sqrt(sumSquaredDiff / sampleCount);
  } else {
    rmsOut = 0.0001;
  }
  
  // Hitung dB dari RMS: dB = 20 * log10(V_rms / V_ref)
  // V_ref = 0.00005V (~ambang batas 30 dB SPL)
  if (rmsOut > 0.00005) {
    dbOut = 20.0 * log10(rmsOut / 0.00005);
  } else {
    dbOut = 30.0;
  }
  
  if (dbOut > 120.0) dbOut = 120.0;
  if (dbOut < 30.0) dbOut = 30.0;
}

void setup() {
  Serial.begin(115200);
  Serial.println("\n[LoudSound] Memulai ESP32 Sound Monitor...");

  analogReadResolution(12);
  pinMode(SOUND_SENSOR_PIN, INPUT);

  // Inisialisasi BLE
  BLEDevice::init("LoudSound-ESP32");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  // 1. Wi-Fi Config Characteristic (Write)
  pWifiConfigChar = pService->createCharacteristic(
                      CHAR_WIFI_CONFIG_UUID,
                      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
                    );
  pWifiConfigChar->setCallbacks(new WifiConfigCallbacks());

  // 2. Wi-Fi Status Characteristic (Read, Notify)
  pWifiStatusChar = pService->createCharacteristic(
                      CHAR_WIFI_STATUS_UUID,
                      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
                    );
  pWifiStatusChar->addDescriptor(new BLE2902());
  pWifiStatusChar->setValue("Belum dikonfigurasi");

  // 3. Sound Telemetry Characteristic (Read, Notify - Mengirim RMS & dB)
  pDecibelChar = pService->createCharacteristic(
                   CHAR_DECIBEL_UUID,
                   BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
                 );
  pDecibelChar->addDescriptor(new BLE2902());
  pDecibelChar->setValue("{\"rms\":0.0000,\"db\":0.0}");

  pService->start();

  // Mulai Advertising BLE
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("[BLE] Siap! Nama perangkat: LoudSound-ESP32. Silakan pairing dari aplikasi Flutter.");
}

unsigned long lastSampleTime = 0;

void loop() {
  // Tangani permintaan koneksi Wi-Fi baru dari BLE
  if (newWifiReceived) {
    newWifiReceived = false;
    connectToWifi(targetSsid, targetPassword);
  }

  // Kirim pembacaan suara (RMS dan dB) setiap 1 detik jika BLE tersambung
  if (millis() - lastSampleTime >= 1000) {
    lastSampleTime = millis();

    float rmsVal = 0.0;
    float dbVal = 0.0;
    readSoundMetrics(rmsVal, dbVal);

    if (deviceConnected && pDecibelChar != NULL) {
      // Kirim format JSON berisi kedua parameter RMS dan dB
      char payload[64];
      snprintf(payload, sizeof(payload), "{\"rms\":%.4f,\"db\":%.1f}", rmsVal, dbVal);
      
      pDecibelChar->setValue(payload);
      pDecibelChar->notify();
      Serial.printf("[Telemetri] Data: %s dikirim via BLE\n", payload);
    }
  }

  // Tangani reconnect advertising jika perangkat mobile putus
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    Serial.println("[BLE] Memulai advertising kembali...");
    oldDeviceConnected = deviceConnected;
  }
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }

  delay(20);
}
