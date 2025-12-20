#include <Arduino.h>
#include <Arduino_GFX_Library.h>
#include <SD.h>
#include <SPI.h>
#include <Wire.h>

// =========================================================
// Waveshare ESP32-S3 Touch AMOLED 1.75" - HARDWARE TEST
// See: .agent/workflows/WAVESHARE_HARDWARE.md
// =========================================================

// I2C Bus (Shared by AXP2101, CST9217, TCA9554, RTC, IMU)
#define IIC_SDA 15
#define IIC_SCL 14

// Touch Controller (CST9217)
#define TOUCH_INT 21
#define TOUCH_ADDR 0x5A

// Display (CO5300 QSPI)
#define LCD_QSPI_CS 12
#define LCD_QSPI_SCK 38
#define LCD_QSPI_D0 4
#define LCD_QSPI_D1 5
#define LCD_QSPI_D2 6
#define LCD_QSPI_D3 7
#define LCD_RESET 39

// SD Card (SPI) - CORRECTED from schematic
#define SD_CS 41
#define SD_MOSI 1
#define SD_MISO 3
#define SD_SCK 2

// I/O Expander (TCA9554) - Controls Touch Reset
#define TCA9554_ADDR 0x20
#define TCA9554_OUTPUT_REG 0x01
#define TCA9554_CONFIG_REG 0x03
#define TCA9554_TOUCH_RST_BIT 0

// Colors
#define WHITE 0xFFFF
#define BLACK 0x0000
#define RED 0xF800
#define GREEN 0x07E0
#define BLUE 0x001F

Arduino_DataBus *bus =
    new Arduino_ESP32QSPI(LCD_QSPI_CS, LCD_QSPI_SCK, LCD_QSPI_D0, LCD_QSPI_D1,
                          LCD_QSPI_D2, LCD_QSPI_D3);
Arduino_GFX *gfx = new Arduino_CO5300(bus, LCD_RESET, 0);

// =========================================================
// I2C Device Scanner
// =========================================================
void scanI2CDevices() {
  Serial.println("\n=== I2C Device Scan ===");

  struct I2CDevice {
    uint8_t addr;
    const char *name;
  };

  I2CDevice knownDevices[] = {
      {0x20, "TCA9554 I/O Expander"}, {0x34, "AXP2101 PMIC"},
      {0x51, "PCF85063 RTC"},         {0x5A, "CST9217 Touch"},
      {0x6A, "QMI8658 IMU (alt)"},    {0x6B, "QMI8658 IMU"},
      {0x18, "ES8311 Audio Codec"},
  };

  int foundCount = 0;
  for (uint8_t addr = 1; addr < 127; addr++) {
    Wire.beginTransmission(addr);
    if (Wire.endTransmission() == 0) {
      // Find device name
      const char *name = "Unknown";
      for (auto &dev : knownDevices) {
        if (dev.addr == addr) {
          name = dev.name;
          break;
        }
      }
      Serial.printf("  0x%02X: %s\n", addr, name);
      foundCount++;
    }
  }
  Serial.printf("Found %d device(s)\n", foundCount);
}

// =========================================================
// TCA9554 Helper Functions
// =========================================================
void tca9554SetPin(uint8_t pin, bool level) {
  Wire.beginTransmission(TCA9554_ADDR);
  Wire.write(TCA9554_OUTPUT_REG);
  Wire.endTransmission(false);
  Wire.requestFrom(TCA9554_ADDR, (uint8_t)1);
  uint8_t current = Wire.available() ? Wire.read() : 0xFF;

  if (level)
    current |= (1 << pin);
  else
    current &= ~(1 << pin);

  Wire.beginTransmission(TCA9554_ADDR);
  Wire.write(TCA9554_OUTPUT_REG);
  Wire.write(current);
  Wire.endTransmission();
}

void tca9554ConfigureOutput(uint8_t pin) {
  Wire.beginTransmission(TCA9554_ADDR);
  Wire.write(TCA9554_CONFIG_REG);
  Wire.endTransmission(false);
  Wire.requestFrom(TCA9554_ADDR, (uint8_t)1);
  uint8_t current = Wire.available() ? Wire.read() : 0xFF;
  current &= ~(1 << pin);

  Wire.beginTransmission(TCA9554_ADDR);
  Wire.write(TCA9554_CONFIG_REG);
  Wire.write(current);
  Wire.endTransmission();
}

void resetTouchViaTCA9554() {
  Serial.println("Resetting Touch via TCA9554...");
  tca9554ConfigureOutput(TCA9554_TOUCH_RST_BIT);
  tca9554SetPin(TCA9554_TOUCH_RST_BIT, false);
  delay(20);
  tca9554SetPin(TCA9554_TOUCH_RST_BIT, true);
  delay(100);
  Serial.println("✓ Touch reset complete.");
}

// =========================================================
// Touch Read (CST92xx format)
// =========================================================
bool readTouch(int16_t *x, int16_t *y) {
  Wire.beginTransmission(TOUCH_ADDR);
  Wire.write(0x00);
  if (Wire.endTransmission(false) != 0)
    return false;

  if (Wire.requestFrom(TOUCH_ADDR, (uint8_t)7) < 7)
    return false;

  uint8_t data[7];
  Wire.readBytes(data, 7);

  uint8_t pressed = (data[0] & 0x0F);
  if (pressed != 0x06)
    return false;

  uint16_t rawX = ((data[1] << 4) | (data[3] >> 4));
  uint16_t rawY = ((data[2] << 4) | (data[3] & 0x0F));

  // Apply coordinate mirroring
  *x = 465 - rawX;
  *y = 465 - rawY;

  return (*x > 0 && *y > 0 && *x < 466 && *y < 466);
}

// =========================================================
// SD Card Test
// =========================================================
bool testSDCard() {
  Serial.println("\n=== SD Card Test ===");
  Serial.printf("Pins: CS=%d, MOSI=%d, MISO=%d, SCK=%d\n", SD_CS, SD_MOSI,
                SD_MISO, SD_SCK);

  // Initialize SPI with custom pins
  SPI.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);

  if (!SD.begin(SD_CS, SPI)) {
    Serial.println("✗ SD Card mount FAILED!");
    Serial.println("  Check: Is card inserted? Is card formatted FAT32?");
    return false;
  }

  uint8_t cardType = SD.cardType();
  if (cardType == CARD_NONE) {
    Serial.println("✗ No SD card detected");
    return false;
  }

  Serial.print("✓ SD Card Type: ");
  if (cardType == CARD_MMC)
    Serial.println("MMC");
  else if (cardType == CARD_SD)
    Serial.println("SD");
  else if (cardType == CARD_SDHC)
    Serial.println("SDHC");
  else
    Serial.println("UNKNOWN");

  uint64_t cardSize = SD.cardSize() / (1024 * 1024);
  Serial.printf("  Card Size: %lluMB\n", cardSize);

  // Test file operations
  File testFile = SD.open("/waveshare_test.txt", FILE_WRITE);
  if (testFile) {
    testFile.println("Waveshare Hardware Test");
    testFile.close();
    Serial.println("✓ File write OK");

    testFile = SD.open("/waveshare_test.txt");
    if (testFile) {
      Serial.println("✓ File read OK");
      testFile.close();
    }
    SD.remove("/waveshare_test.txt");
  } else {
    Serial.println("✗ File write FAILED");
    return false;
  }

  return true;
}

// =========================================================
// I2C Bus Recovery - CRITICAL for stuck bus
// =========================================================
void i2cBusRecovery() {
  Serial.println("Performing I2C bus recovery...");

  // Configure pins as GPIO for manual control (Wire not started yet)
  pinMode(IIC_SDA, INPUT_PULLUP);
  pinMode(IIC_SCL, OUTPUT);

  // Clock SCL up to 9 times while monitoring SDA
  // This releases any slave holding SDA low
  int clockCount = 0;
  for (int i = 0; i < 9; i++) {
    digitalWrite(IIC_SCL, LOW);
    delayMicroseconds(5);
    digitalWrite(IIC_SCL, HIGH);
    delayMicroseconds(5);
    clockCount++;

    // If SDA is released (high), we might be done
    if (digitalRead(IIC_SDA) == HIGH) {
      break;
    }
  }

  // Generate STOP condition: SDA low-to-high while SCL high
  pinMode(IIC_SDA, OUTPUT);
  digitalWrite(IIC_SDA, LOW);
  delayMicroseconds(5);
  digitalWrite(IIC_SCL, HIGH);
  delayMicroseconds(5);
  digitalWrite(IIC_SDA, HIGH);
  delayMicroseconds(5);

  Serial.printf("✓ I2C bus recovery done (%d clocks)\n", clockCount);
}

// =========================================================
// Setup
// =========================================================
void setup() {
  Serial.begin(115200);
  delay(3000);
  Serial.println("\n\n========================================");
  Serial.println("  WAVESHARE AMOLED 1.75\" HARDWARE TEST");
  Serial.println("========================================");

  // 0. FIRST: Perform bus recovery BEFORE Wire.begin()
  i2cBusRecovery();

  // 1. Initialize I2C with explicit settings
  Wire.begin(IIC_SDA, IIC_SCL, 100000U);
  Wire.setBufferSize(128);
  Wire.setTimeOut(100);
  Serial.println("✓ I2C Initialized (100kHz)");

  // 2. Power on AXP2101
  Wire.beginTransmission(0x34);
  if (Wire.endTransmission() == 0) {
    auto send = [](uint8_t reg, uint8_t val) {
      Wire.beginTransmission(0x34);
      Wire.write(reg);
      Wire.write(val);
      Wire.endTransmission();
    };
    send(0x90, 0x9C);
    uint8_t ldo_regs[] = {0x92, 0x93, 0x94, 0x95, 0x96, 0x97};
    for (uint8_t reg : ldo_regs)
      send(reg, 0x9C);
    Serial.println("✓ AXP2101 Power Enabled");
  } else {
    Serial.println("✗ AXP2101 NOT found!");
  }

  // 3. Scan I2C bus
  scanI2CDevices();

  // 4. Reset touch via TCA9554
  Wire.beginTransmission(TCA9554_ADDR);
  if (Wire.endTransmission() == 0) {
    resetTouchViaTCA9554();
  }

  // 5. Test SD Card
  bool sdOk = testSDCard();

  // 6. Init Display
  gfx->begin(34000000);
  ((Arduino_OLED *)gfx)->setBrightness(200);
  gfx->fillScreen(WHITE);
  gfx->setTextColor(BLACK);
  gfx->setCursor(20, 50);
  gfx->setTextSize(2);
  gfx->println("Hardware Test");
  gfx->setCursor(20, 100);
  gfx->printf("SD Card: %s", sdOk ? "OK" : "FAIL");
  gfx->setCursor(20, 150);
  gfx->println("Touch: Active");

  Serial.println("\n=== TEST COMPLETE ===");
  Serial.println("Touch the screen to verify touch coordinates.");
}

// =========================================================
// Loop
// =========================================================
void loop() {
  int16_t x, y;
  if (readTouch(&x, &y)) {
    Serial.printf("TOUCH: (%d, %d)\n", x, y);
    gfx->fillCircle(x, y, 8, GREEN);
  }
  delay(20);
}
