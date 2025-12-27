/**
 * Enhanced debug test - matches esp32 project exactly
 */

#include <Arduino.h>
#include <Wire.h>
#include <Arduino_GFX_Library.h>

// EXACT pin configuration from working esp32 project
#define TFT_CS    12
#define TFT_CLK   38
#define TFT_D0    4
#define TFT_D1    5
#define TFT_D2    6
#define TFT_D3    7
#define TFT_RST   39

#define TOUCH_SDA 15
#define TOUCH_SCL 14

#define AXP2101_I2C_ADDRESS 0x34

// QSPI Bus - EXACT constructor from working project
Arduino_ESP32QSPI *bus = new Arduino_ESP32QSPI(
  TFT_CS,   // CS
  TFT_CLK,  // SCK
  TFT_D0,   // D0
  TFT_D1,   // D1
  TFT_D2,   // D2
  TFT_D3    // D3
);

// CO5300 Display Driver - EXACT constructor from working project
Arduino_CO5300 *gfx = new Arduino_CO5300(
  bus,
  TFT_RST,      // RST
  0             // Rotation only
);

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n\n=== Debug: EXACT Working Project Initialization ===");
  
  // Initialize I2C - EXACT sequence from working project
  Wire.begin(TOUCH_SDA, TOUCH_SCL);
  Wire.setClock(400000);  // 400kHz I2C clock
  delay(50);
  Serial.println("✓ I2C initialized");
  
  // Initialize AXP2101 - EXACT sequence from working project
  Serial.println("Enabling display power via AXP2101...");
  Wire.beginTransmission(AXP2101_I2C_ADDRESS);
  if (Wire.endTransmission() == 0) {
    Serial.println("✓ AXP2101 found!");
    
    // Enable DLDO1 output (3.3V for display)
    Wire.beginTransmission(AXP2101_I2C_ADDRESS);
    Wire.write(0x90);  // DLDO1 voltage setting register
    Wire.write(0x1C);  // Set to 3.3V
    Wire.endTransmission();
    
    Wire.beginTransmission(AXP2101_I2C_ADDRESS);
    Wire.write(0x90);  // Enable DLDO1
    Wire.write(0x9C);  // Enable bit + 3.3V
    Wire.endTransmission();
    
    delay(100);
    Serial.println("✓ AXP2101 display power enabled");
  } else {
    Serial.println("✗ AXP2101 not found!");
  }
  
  // Initialize display - EXACT sequence from working project
  Serial.println("Initializing display...");
  gfx->begin();
  delay(100);  // Let display stabilize
  
  Serial.println("Turning on display and setting brightness...");
  gfx->displayOn();
  delay(50);
  gfx->setBrightness(255);  // Maximum brightness 0-255
  delay(50);
  
  // Clear screen first (like working project)
  Serial.println("Clearing screen to BLACK...");
  gfx->fillScreen(0x0000);  // BLACK
  delay(500);
  Serial.println("Display ready");
  
  // Now draw test patterns
  Serial.println("\nDrawing test patterns...");
  
  Serial.println("1. RED screen");
  gfx->fillScreen(0xF800);
  delay(1000);
  
  Serial.println("2. GREEN screen");
  gfx->fillScreen(0x07E0);
  delay(1000);
  
  Serial.println("3. BLUE screen");
  gfx->fillScreen(0x001F);
  delay(1000);
  
  Serial.println("4. WHITE screen");
  gfx->fillScreen(0xFFFF);
  delay(1000);
  
  // Draw test pattern
  Serial.println("5. Drawing test graphics");
  gfx->fillScreen(0x0000);  // BLACK background
  
  gfx->setTextColor(0xFFFF);  // WHITE text
  gfx->setTextSize(3);
  gfx->setCursor(100, 200);
  gfx->println("WORKING?");
  
  gfx->drawRect(50, 50, 366, 366, 0x07E0);  // GREEN rectangle
  gfx->fillCircle(233, 233, 80, 0xF800);  // RED circle
  
  Serial.println("\n✓ Test complete!");
  Serial.println("If display is still black, hardware or driver issue exists");
}

void loop() {
  // Pulsing indicator
  static uint8_t brightness = 0;
  static int8_t direction = 1;
  
  brightness += direction;
  if (brightness == 0 || brightness == 255) {
    direction = -direction;
  }
  
  uint16_t color = gfx->color565(brightness, 0, 255-brightness);
  gfx->fillCircle(233, 400, 30, color);
  delay(10);
}

