/**
 * Simple display test for Waveshare AMOLED with Arduino_GFX
 * This minimal test proves the display hardware works
 */

#include <Arduino.h>
#include <Wire.h>
#include <Arduino_GFX_Library.h>

// Display pins (QSPI)
#define TFT_CS 12
#define TFT_SCK 38
#define TFT_D0 4
#define TFT_D1 5
#define TFT_D2 6
#define TFT_D3 7
#define TFT_RST 39

// I2C pins for AXP2101 (matches working esp32 project)
#define I2C_SDA 15
#define I2C_SCL 14  // CRITICAL: Must be 14, not 16!

Arduino_ESP32QSPI *bus = nullptr;
Arduino_CO5300 *gfx = nullptr;

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n\n=== Waveshare AMOLED Display Test ===");

  // Initialize I2C for AXP2101
  Wire.begin(I2C_SDA, I2C_SCL);
  Wire.setClock(400000);  // 400kHz I2C clock (Fast Mode)
  delay(50);

  // Enable display power via AXP2101
  Serial.println("Configuring AXP2101 power...");
  Wire.beginTransmission(0x34);
  if (Wire.endTransmission() == 0) {
    Serial.println("✓ AXP2101 detected");
    
    // Enable DLDO1 at 3.3V for display
    Wire.beginTransmission(0x34);
    Wire.write(0x90);
    Wire.write(0x9C);  // Enable + 3.3V
    Wire.endTransmission();
    
    delay(100);
    Serial.println("✓ Display power enabled");
  } else {
    Serial.println("✗ AXP2101 not found!");
  }

  // Initialize QSPI display
  Serial.println("Initializing CO5300 AMOLED display...");
  bus = new Arduino_ESP32QSPI(
    TFT_CS,   /* CS */
    TFT_SCK,  /* SCK */
    TFT_D0,   /* D0/MOSI */
    TFT_D1,   /* D1/MISO */
    TFT_D2,   /* D2 */
    TFT_D3    /* D3 */
  );
  
  // Use 3-parameter constructor like working project (no IPS parameter!)
  gfx = new Arduino_CO5300(bus, TFT_RST, 0 /* rotation */);
  
  gfx->begin();
  delay(100);  // Let display stabilize after initialization
  
  Serial.println("Turning on display and setting brightness...");
  gfx->displayOn();
  delay(50);  // CRITICAL: Wait for display to turn on
  
  gfx->setBrightness(255);  // Maximum brightness
  delay(50);  // CRITICAL: Wait for brightness to take effect
  
  Serial.println("✓ Display initialized and powered on!");
  
  // Test pattern
  Serial.println("Drawing test pattern...");
  
  gfx->fillScreen(0x0000);  // BLACK
  delay(500);
  
  gfx->fillScreen(0xF800);  // RED
  delay(500);
  
  gfx->fillScreen(0x07E0);  // GREEN
  delay(500);
  
  gfx->fillScreen(0x001F);  // BLUE
  delay(500);
  
  // Draw some shapes
  gfx->fillScreen(0x0000);  // BLACK
  gfx->setTextColor(0xFFFF);  // WHITE
  gfx->setTextSize(2);
  gfx->setCursor(50, 100);
  gfx->println("IceNav");
  gfx->setCursor(50, 130);
  gfx->println("AMOLED Test");
  
  gfx->drawRect(10, 10, 446, 446, 0x07E0);  // GREEN
  gfx->fillCircle(233, 233, 50, 0x001F);  // BLUE
  
  Serial.println("✓ Test complete! Display should show pattern.");
}

void loop() {
  // Cycle colors slowly
  static uint8_t hue = 0;
  hue += 1;
  uint16_t color = gfx->color565(hue, 255-hue, 128);
  gfx->fillCircle(233, 350, 30, color);
  delay(50);
}

