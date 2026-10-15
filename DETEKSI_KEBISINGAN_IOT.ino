#include <Arduino.h>
#include <driver/i2s.h>
#include <math.h>

// Library khusus BLE
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// =====================================
// KONFIGURASI BLE (UUID)
// =====================================
#define SERVICE_UUID        "4fa8c001-124e-423a-bc3f-923de9dc001e"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

BLECharacteristic *pCharacteristic;
bool deviceConnected = false;

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
// KONFIGURASI AUDIO & HISTERESIS
// =====================================
#define SAMPLE_RATE 16000
#define SAMPLE_COUNT 1024

int32_t samples[SAMPLE_COUNT];

const double THRESHOLD_HIGH = 120.0;
const double THRESHOLD_LOW  = 70.0;

bool isLoud = false;

unsigned long previousMillis = 0;
const long INTERVAL = 1000;

double sum_rms_per_second = 0;
int sample_blocks_count = 0;

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
// FUNGSI BUNYI BUZZER 3 KALI
// =====================================
void triggerBuzzerAlert() {
  for (int i = 0; i < 3; i++) {
    digitalWrite(BUZZER_PIN, HIGH);
    delay(150);
    digitalWrite(BUZZER_PIN, LOW);
    delay(150);
  }
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
  BLEDevice::init("Noise_Monitor");
  BLEServer *pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  // Buat BLE Service
  BLEService *pService = pServer->createService(SERVICE_UUID);

  // Buat BLE Characteristic dengan fitur READ dan NOTIFY
  pCharacteristic = pService->createCharacteristic(
                      CHARACTERISTIC_UUID,
                      BLECharacteristic::PROPERTY_READ   |
                      BLECharacteristic::PROPERTY_NOTIFY
                    );

  // Tambahkan Descriptor 2902 untuk mendukung Notifikasi
  pCharacteristic->addDescriptor(new BLE2902());

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

  previousMillis = millis();
}

// =====================================
// LOOP
// =====================================
void loop() {
  size_t bytes_read = 0;
  esp_err_t err = i2s_read(I2S_PORT, samples, sizeof(samples), &bytes_read, portMAX_DELAY);

  if (err != ESP_OK || bytes_read == 0) return;

  int count = bytes_read / sizeof(int32_t);
  double sum_squares = 0.0;

  for (int i = 0; i < count; i++) {
    int32_t sample = samples[i] >> 8;
    sum_squares += (double)sample * (double)sample;
  }

  double block_rms = sqrt(sum_squares / count);
  double scaled_rms = block_rms / 10000.0;

  sum_rms_per_second += scaled_rms;
  sample_blocks_count++;

  unsigned long currentMillis = millis();
  if (currentMillis - previousMillis >= INTERVAL) {
    previousMillis = currentMillis;

    double current_avg_rms = (sample_blocks_count > 0) ? (sum_rms_per_second / sample_blocks_count) : 0;

    // Logika Histeresis
    if (!isLoud && current_avg_rms >= THRESHOLD_HIGH) {
      isLoud = true;
    } else if (isLoud && current_avg_rms < THRESHOLD_LOW) {
      isLoud = false;
    }

    // Jika status berisik, bunyikan buzzer
    if (isLoud) {
      triggerBuzzerAlert();
    }

    const char* status = isLoud ? "TERLALU BERISIK" : "NORMAL";

    // Tampilkan di Serial Monitor Laptop
    Serial.printf("RMS: %6.1f | Status: %s\n", current_avg_rms, status);

    // Kirim Data via BLE (Hanya jika ada perangkat yang terhubung)
    if (deviceConnected) {
      char jsonBuffer[128]; // <-- Diperbesar agar teks panjang muat
      snprintf(jsonBuffer, sizeof(jsonBuffer), "{\"rms\":%.1f,\"status\":\"%s\"}", 
               current_avg_rms, 
               isLoud ? "TERLALU BERISIK" : "NORMAL");

      pCharacteristic->setValue(jsonBuffer);
      pCharacteristic->notify();
    }

    // Reset Akumulator
    sum_rms_per_second = 0;
    sample_blocks_count = 0;
  }
}