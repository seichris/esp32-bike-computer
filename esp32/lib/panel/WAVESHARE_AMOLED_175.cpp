/**
 * @file WAVESHARE_AMOLED_175.cpp
 * @brief Waveshare 1.75 AMOLED (CO5300) implementation for IceNav using
 * Arduino_GFX
 */

#include "WAVESHARE_AMOLED_175.hpp"

#ifdef USE_ARDUINO_GFX

#include <cstring>
#include <Preferences.h>

// Include HAL for pin definitions
#include "../../include/hal.hpp"
#include "i2c_bus.hpp"
#include "touch.hpp"
#include "waveshare_board.hpp"

// Define Global Variables declared extern in hal.hpp
uint8_t GPS_TX = GPIO_NUM_43;
uint8_t GPS_RX = GPIO_NUM_44;

// ============================================================================
// DISPLAY CONFIGURATION (Arduino_GFX)
// ============================================================================

// QSPI Bus for CO5300 - matches working esp32 project
Arduino_ESP32QSPI *bus = new Arduino_ESP32QSPI(12, // CS
                                               38, // SCK
                                               4,  // D0
                                               5,  // D1
                                               6,  // D2
                                               7   // D3
);

// CO5300 Display Driver - Use minimal constructor (works for 0° mode)
// Note: Explicit offsets caused green edges, so use defaults
Arduino_CO5300 *gfx = new Arduino_CO5300(bus,
                                         39, // RST
                                         0   // Rotation
);

// ============================================================================
// LVGL 9 DISPLAY BUFFER
// ============================================================================

extern lv_display_t *display;
static lv_color_t *disp_draw_buf = NULL;
static uint8_t displayRotation =
    0; // Global rotation for touch coordinate transform
volatile uint32_t displayFlushCount = 0;
volatile uint32_t lastDisplayFlushMs = 0;
volatile uint32_t lastDisplayFlushDurationUs = 0;
volatile uint32_t maxDisplayFlushDurationUs = 0;

// ============================================================================
// LVGL 9 DISPLAY FLUSH CALLBACK
// Using low-level methods for proper partial update handling
// ============================================================================

void my_disp_flush(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map) {
  uint32_t startUs = micros();
  uint32_t w = (area->x2 - area->x1 + 1);
  uint32_t h = (area->y2 - area->y1 + 1);

  // Use low-level Arduino_GFX methods for proper partial update
  // This avoids potential issues with draw16bitRGBBitmap on partial regions
  gfx->startWrite();
  gfx->writeAddrWindow(area->x1, area->y1, w, h);
  gfx->writePixels((uint16_t *)px_map, w * h);
  gfx->endWrite();

  // Inform LVGL 9 that flushing is complete
  lv_display_flush_ready(disp);
  uint32_t durationUs = micros() - startUs;
  displayFlushCount++;
  lastDisplayFlushMs = millis();
  lastDisplayFlushDurationUs = durationUs;
  if (durationUs > maxDisplayFlushDurationUs) {
    maxDisplayFlushDurationUs = durationUs;
  }
}

// ============================================================================
// TOUCH DRIVER (CST9217) - WITH TCA9554 RESET AND I2C BUS RECOVERY
// See WAVESHARE_HARDWARE.md.
// ============================================================================

bool touchPressed = false;
uint16_t touchX = 0, touchY = 0;
static bool touchInitialized = false;
static bool touchHintConfigured = false;
static uint32_t lastTouchInitAttemptMs = 0;
static uint32_t lastTouchReadMs = 0;
static uint32_t touchBackoffUntilMs = 0;
static uint32_t lastTouchErrorLogMs = 0;
static uint32_t lastTouchDebugLogMs = 0;
static uint32_t lastTouchRawLogMs = 0;
static uint32_t touchFastPollUntilMs = 0;
static uint32_t lastValidTouchMs = 0;
static uint32_t lastTouchHintActiveMs = 0;
static uint32_t lastTouchHintChangeMs = 0;
static uint8_t consecutiveTouchReadFailures = 0;
static uint8_t tca9554OutputShadow = 0xFF;
static uint8_t tca9554ConfigShadow = 0xFF;
static bool lastTouchHintActive = false;
static bool touchHintStateKnown = false;

static bool isValidTouchCoordinate(uint16_t x, uint16_t y) {
  return x < waveshare_board::touch::ACTIVE_WIDTH &&
         y < waveshare_board::touch::ACTIVE_HEIGHT;
}

static bool readCst9217Register(uint16_t reg, uint8_t *data, uint8_t len) {
  return waveshare_board::i2c::readRegister16(
      waveshare_board::touch::CST9217_ADDR, reg, data, len, "CST9217");
}

static void logTouchPacket(const char *label, const uint8_t *data,
                           uint8_t length, uint16_t rawX, uint16_t rawY,
                           bool interruptActive, uint32_t now) {
  bool isPoint = strncmp(label, "point", 5) == 0;
  uint32_t minInterval = isPoint ? 1000 : 10000;
  if (now - lastTouchRawLogMs <= minInterval) {
    return;
  }

  Serial.printf("Touch raw: %s raw=(%u,%u) int=%s bytes=", label, rawX, rawY,
                interruptActive ? "LOW(active)" : "HIGH(idle)");
  for (uint8_t i = 0; i < length && i < 7; i++) {
    Serial.printf("%02X", data[i]);
    if (i + 1 < length && i < 6) {
      Serial.print(" ");
    }
  }
  Serial.println();
  lastTouchRawLogMs = now;
}

static void setTouchPressed(bool pressed) {
  if (pressed != touchPressed) {
    if (pressed) {
      Serial.printf("Touch: press x=%u y=%u\n", touchX, touchY);
    } else {
      Serial.println("Touch: release");
    }
  }
  touchPressed = pressed;
}

static void configureTouchHintPin() {
  if (touchHintConfigured) {
    return;
  }

  pinMode(waveshare_board::touch::CST9217_INT_PIN, INPUT_PULLUP);
  touchHintConfigured = true;
}

static bool isTouchHintActive() {
  configureTouchHintPin();
  return digitalRead(waveshare_board::touch::CST9217_INT_PIN) == LOW;
}

static bool updateTouchHintState(bool active, uint32_t now) {
  bool changed = !touchHintStateKnown || active != lastTouchHintActive;
  bool heartbeat = now - lastTouchDebugLogMs > 10000;

  if (active) {
    lastTouchHintActiveMs = now;
  }
  if (changed) {
    lastTouchHintChangeMs = now;
    if (active) {
      touchFastPollUntilMs =
          now + waveshare_board::touch::HINT_FAST_POLL_WINDOW_MS;
    }
  }

  if (changed || heartbeat) {
    uint32_t msSinceHintChange =
        lastTouchHintChangeMs == 0 ? 0 : now - lastTouchHintChangeMs;
    Serial.printf("Touch debug: init=%d int=%s pressed=%d hint_age_ms=%lu\n",
                  touchInitialized, active ? "LOW(active)" : "HIGH(idle)",
                  touchPressed, static_cast<unsigned long>(msSinceHintChange));
    lastTouchDebugLogMs = now;
    lastTouchHintActive = active;
    touchHintStateKnown = true;
  }

  return changed;
}

static uint32_t idleFailureRetryMs() {
  uint32_t retryMs = waveshare_board::touch::IDLE_FAILURE_BASE_RETRY_MS;
  if (consecutiveTouchReadFailures > 1) {
    retryMs += static_cast<uint32_t>(consecutiveTouchReadFailures - 1) * 75;
  }
  if (retryMs > waveshare_board::touch::IDLE_FAILURE_MAX_RETRY_MS) {
    retryMs = waveshare_board::touch::IDLE_FAILURE_MAX_RETRY_MS;
  }
  return retryMs;
}

static uint32_t touchReadInterval(bool hintActive, bool hintChanged,
                                  uint32_t now) {
  if (hintChanged && hintActive) {
    return 0;
  }
  if (hintActive) {
    return waveshare_board::touch::HINT_ACTIVE_READ_INTERVAL_MS;
  }
  if (touchPressed) {
    return waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
  }
  if (lastTouchHintActiveMs != 0 &&
      now - lastTouchHintActiveMs <
          waveshare_board::touch::HINT_FAST_POLL_WINDOW_MS) {
    return waveshare_board::touch::RECENT_HINT_READ_INTERVAL_MS;
  }
  if (now < touchFastPollUntilMs) {
    return waveshare_board::touch::FAST_FALLBACK_READ_INTERVAL_MS;
  }
  return waveshare_board::touch::IDLE_FALLBACK_READ_INTERVAL_MS;
}

static void noteTouchReadFailure(const char *reason, uint32_t now) {
  consecutiveTouchReadFailures++;

  if (now - lastTouchErrorLogMs > 5000) {
    Serial.printf("Touch read failed: %s (failures=%u)\n", reason,
                  consecutiveTouchReadFailures);
    lastTouchErrorLogMs = now;
  }

  if (touchPressed &&
      now - lastValidTouchMs < waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
    touchBackoffUntilMs =
        now + waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
    return;
  }

  if (!touchPressed) {
    touchBackoffUntilMs = now + idleFailureRetryMs();
    if (consecutiveTouchReadFailures > 20) {
      consecutiveTouchReadFailures = 0;
    }
    return;
  }

  setTouchPressed(false);
  touchBackoffUntilMs = now + 250;
  if (consecutiveTouchReadFailures >= 5) {
    touchInitialized = false;
    touchBackoffUntilMs = now + waveshare_board::touch::REINIT_BACKOFF_MS;
    consecutiveTouchReadFailures = 0;
  }
}

// TCA9554 helper functions
static bool tca9554SetPin(uint8_t pin, bool level) {
  if (level) {
    tca9554OutputShadow |= (1 << pin);
  } else {
    tca9554OutputShadow &= ~(1 << pin);
  }

  return waveshare_board::i2c::writeRegister8(
      waveshare_board::TCA9554_ADDR, waveshare_board::touch::TCA9554_OUTPUT_REG,
      tca9554OutputShadow, "TCA9554");
}

static bool tca9554ConfigureOutput(uint8_t pin) {
  tca9554ConfigShadow &= ~(1 << pin); // Clear bit = Output

  return waveshare_board::i2c::writeRegister8(
      waveshare_board::TCA9554_ADDR, waveshare_board::touch::TCA9554_CONFIG_REG,
      tca9554ConfigShadow, "TCA9554");
}

void initTouchController() {
  if (touchInitialized)
    return;

  uint32_t now = millis();
  if (lastTouchInitAttemptMs != 0 && now - lastTouchInitAttemptMs < 5000) {
    return;
  }
  lastTouchInitAttemptMs = now;
  configureTouchHintPin();

  // Check for TCA9554 and reset touch controller
  if (waveshare_board::i2c::probe(waveshare_board::TCA9554_ADDR, "TCA9554")) {
    Serial.println("✓ TCA9554 found - resetting touch controller");
    bool resetOk =
        tca9554ConfigureOutput(waveshare_board::touch::TCA9554_TOUCH_RST_BIT);
    resetOk =
        tca9554SetPin(waveshare_board::touch::TCA9554_TOUCH_RST_BIT, false) &&
        resetOk; // RST low
    delay(20);
    resetOk =
        tca9554SetPin(waveshare_board::touch::TCA9554_TOUCH_RST_BIT, true) &&
        resetOk; // RST high
    delay(100); // Wait for touch controller to boot
    touchInitialized = resetOk;
    if (!resetOk) {
      Serial.println("Touch reset failed through TCA9554");
    }
  } else {
    Serial.println("✗ TCA9554 not found - touch may not work");
  }
}

void readTouch() {
  uint32_t now = millis();
  bool touchHintActive = isTouchHintActive();
  bool touchHintChanged = updateTouchHintState(touchHintActive, now);

  if (now < touchBackoffUntilMs && !(touchHintChanged && touchHintActive)) {
    if (touchPressed && now - lastValidTouchMs <
                            waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
      return;
    }
    setTouchPressed(false);
    return;
  }

  // Initialize touch on first read
  if (!touchInitialized) {
    initTouchController();
    if (!touchInitialized) {
      setTouchPressed(false);
      return;
    }
  }

  uint32_t readInterval =
      touchReadInterval(touchHintActive, touchHintChanged, now);
  if (now - lastTouchReadMs < readInterval) {
    return;
  }
  lastTouchReadMs = now;

  uint8_t data[waveshare_board::touch::CST9217_DATA_LENGTH] = {0};
  if (!readCst9217Register(waveshare_board::touch::CST9217_DATA_REG, data,
                           sizeof(data))) {
    noteTouchReadFailure("data read", now);
    return;
  }
  consecutiveTouchReadFailures = 0;

  if (data[6] != waveshare_board::touch::CST9217_ACK) {
    logTouchPacket("ignored-no-ack", data, sizeof(data), 0, 0,
                   touchHintActive, now);
    if (touchPressed && now - lastValidTouchMs <
                            waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
      touchBackoffUntilMs =
          now + waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
      return;
    }
    setTouchPressed(false);
    return;
  }

  uint8_t points = data[5] & 0x7F;
  if (points == 0) {
    if (touchPressed && now - lastValidTouchMs <
                            waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
      touchBackoffUntilMs =
          now + waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
      return;
    }
    setTouchPressed(false);
    return;
  }

  uint8_t status = data[0] & 0x0F;
  uint16_t rawX = (data[1] << 4) | (data[3] >> 4);
  uint16_t rawY = (data[2] << 4) | (data[3] & 0x0F);
  if (status != 0x00 && status != 0x06) {
    logTouchPacket("ignored-status", data, sizeof(data), rawX, rawY,
                   touchHintActive, now);
    if (touchPressed && now - lastValidTouchMs <
                            waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
      touchBackoffUntilMs =
          now + waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
      return;
    }
    setTouchPressed(false);
    return;
  }
  if (!isValidTouchCoordinate(rawX, rawY)) {
    logTouchPacket("ignored-invalid", data, sizeof(data), rawX, rawY,
                   touchHintActive, now);
    setTouchPressed(false);
    return;
  }

  bool moved = rawX != touchX || rawY != touchY;
  if (status == 0x00 && !touchPressed) {
    logTouchPacket("ignored-stale-start", data, sizeof(data), rawX, rawY,
                   touchHintActive, now);
    setTouchPressed(false);
    return;
  }
  if (status == 0x00 && !moved &&
      now - lastValidTouchMs >= waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
    setTouchPressed(false);
    return;
  }

  touchX = rawX;
  touchY = rawY;
  if (status == 0x06 || moved) {
    lastValidTouchMs = now;
  }
  touchFastPollUntilMs =
      now + waveshare_board::touch::TOUCH_FAST_POLL_WINDOW_MS;
  logTouchPacket(status == 0x06 ? "point" : "point-status0", data,
                 sizeof(data), touchX, touchY, touchHintActive, now);

  // Clamp to screen bounds
  if (touchX >= waveshare_board::touch::ACTIVE_WIDTH)
    touchX = waveshare_board::touch::MAX_X;
  if (touchY >= waveshare_board::touch::ACTIVE_HEIGHT)
    touchY = waveshare_board::touch::MAX_Y;

  setTouchPressed(true);
}

void my_touchpad_read(lv_indev_t *indev_driver, lv_indev_data_t *data) {
  readTouch();

  if (touchPressed) {
    data->state = LV_INDEV_STATE_PRESSED;
    // Rotate touch coordinates to match display rotation
    uint16_t rotatedX = touchX;
    uint16_t rotatedY = touchY;
    switch (displayRotation) {
    case 1: // 90° CCW: swap X/Y and flip new X
      rotatedX = touchY;
      rotatedY = waveshare_board::touch::MAX_Y - touchX;
      break;
    case 2: // 180°: flip both
      rotatedX = waveshare_board::touch::MAX_X - touchX;
      rotatedY = waveshare_board::touch::MAX_Y - touchY;
      break;
    case 3: // 270° CCW: swap X/Y and flip new Y
      rotatedX = waveshare_board::touch::MAX_X - touchY;
      rotatedY = touchX;
      break;
    }
    data->point.x = rotatedX;
    data->point.y = rotatedY;
  } else {
    data->state = LV_INDEV_STATE_RELEASED;
  }
}

// ============================================================================
// DISPLAY SETUP FUNCTIONS
// ============================================================================

void setupDisplay() {
  Serial.println("Initializing Arduino_GFX display...");

  // Initialize display
  gfx->begin();
  delay(100); // Let display stabilize

  // Load rotation from NVS (default to 0 if not set)
  Preferences prefs;
  prefs.begin("mapSettings", true); // read-only
  uint8_t rotation = prefs.getUChar("rotation", 0);
  prefs.end();
  displayRotation = rotation; // Store globally for touch coordinate rotation
  Serial.printf("Loaded rotation from NVS: %d\n", rotation);

  // ============================================================================
  // DISPLAY ROTATION VIA RAW MADCTL COMMAND
  // ============================================================================
  // CO5300 MADCTL register (0x36) bits:
  // - Standard panels use: 0x80=MY, 0x40=MX, 0x20=MV (row/col exchange)
  // - CO5300 uses different bits: 0x02=X_FLIP, 0x05=Y_FLIP, 0x20=MV
  //
  // IMPORTANT: CO5300 hardware only supports 0° and 90° rotation!
  // 180° and 270° attempts all resulted in mirroring or wrong direction.
  //
  // === 180° ROTATION ATTEMPTS (all failed): ===
  // - 0x07 (X_FLIP + Y_FLIP): shows 0° mirrored
  // - 0x27 (MV + X_FLIP + Y_FLIP): shows same as 90°
  // - 0x25 (MV + Y_FLIP): shows 270° mirrored
  // - 0x05 (Y_FLIP only): shows same as 0°
  //
  // === 270° ROTATION ATTEMPTS (all failed): ===
  // - 0x25 (MV + Y_FLIP): mirrored
  // - 0x02 (X_FLIP only): shows 0° mirrored
  // - 0x07 (X_FLIP + Y_FLIP): shows 0° mirrored
  // - 0x20 (MV only): correct direction but mirrored
  //
  // ============================================================================
  // KNOWN ISSUE: 90° ROTATION HAS GREEN EDGE AT BOTTOM
  // ============================================================================
  // When 90° rotation is enabled, a thin green strip appears at the bottom
  // of the display. The map and touch work correctly, but this visual artifact
  // persists during all map operations.
  //
  // === WHAT WE TRIED TO FIX THE GREEN EDGE (all failed): ===
  // 1. fillScreen(BLACK) after MADCTL - still shows green
  // 2. fillScreen(BLACK) after rotation in LVGL setup - still shows green
  // 3. Explicit constructor with 466x466 dimensions and 7px offsets
  //    (center in 480x480 panel) - made it worse, added green to 0° mode too
  // 4. Various MADCTL bit combinations - didn't help
  //
  // === POSSIBLE ROOT CAUSES (for future investigation): ===
  // - CO5300 panel is 480x480, we use 466x466 window
  // - When MV (row/col swap) is set, the address window offsets may not
  //   adjust correctly in the Arduino_CO5300 driver
  // - The driver's writeAddrWindow() adds _xStart/_yStart offsets which
  //   may not be correct for rotated mode
  // - LVGL or map buffer may not be fully covering the rotated display area
  //
  // === POTENTIAL FIXES TO TRY IN FUTURE: ===
  // - Modify Arduino_CO5300 driver to handle rotation offsets properly
  // - Send custom CASET/PASET commands after MADCTL to adjust window
  // - Use LVGL's software rotation (lv_display_set_rotation) with proper
  //   render mode configuration
  // - Investigate if the green is from uninitialized PSRAM buffer
  //
  // For now, the iOS app still offers 90° rotation option with this known
  // visual artifact (green strip at bottom). Touch and map work correctly.
  // ============================================================================
  //
  if (rotation == 1) {
    // 90° CCW - MV + X_FLIP (rotation works, touch works, but green edge issue)
    uint8_t madctl = 0x20 | 0x02; // MV + X_FLIP = 0x22
    Serial.printf("Sending raw MADCTL: 0x%02X for 90° rotation\n", madctl);
    gfx->startWrite();
    bus->writeC8D8(0x36, madctl);
    gfx->endWrite();
    // Clear display RAM with new rotation coordinate system
    gfx->fillScreen(0x0000); // BLACK - important to clear after rotation!
  }
  // Note: rotation values 2 (180°) and 3 (270°) are not supported by CO5300
  // The iOS app only offers 0° and 90° options

  // Turn on display and set brightness (CRITICAL for AMOLED!)
  Serial.println("Turning on display and setting brightness...");
  gfx->displayOn();
  delay(50);
  gfx->setBrightness(255); // Maximum brightness 0-255
  delay(50);

  // Clear screen for LVGL
  gfx->fillScreen(0x0000); // BLACK
  Serial.println("Arduino_GFX display ready");
}

void setupLVGLforArduinoGFX() {
  Serial.println("Initializing LVGL 9 with Arduino_GFX...");

  lv_init();

  // Create display using LVGL 9 API
  display = lv_display_create(SCREEN_WIDTH, SCREEN_HEIGHT);
  if (display == NULL) {
    Serial.println("ERROR: LVGL display creation failed!");
    while (1)
      delay(1000);
  }

  // Set flush callback
  lv_display_set_flush_cb(display, my_disp_flush);

  // Allocate FULL SCREEN buffer to avoid stripe artifacts at partial flush
  // boundaries With PSRAM available, we can afford the full 466x466x2 = 434312
  // bytes
  size_t bufSize = SCREEN_WIDTH * SCREEN_HEIGHT; // Full screen
#ifdef BOARD_HAS_PSRAM
  Serial.printf("DEBUG: LV_COLOR_DEPTH=%d, sizeof(lv_color_t)=%d (Using "
                "RGB565=2 bytes)\n",
                LV_COLOR_DEPTH, sizeof(lv_color_t));
  Serial.printf("Allocating FULL SCREEN LVGL buffer: %d bytes (using PSRAM)\n",
                bufSize * sizeof(uint16_t)); // Use 2 bytes for RGB565!
  // Allocate full screen buffer from PSRAM
  disp_draw_buf = (lv_color_t *)heap_caps_aligned_alloc(
      16, bufSize * sizeof(uint16_t), MALLOC_CAP_SPIRAM); // RGB565 = 2 bytes
  if (!disp_draw_buf) {
    Serial.println("PSRAM allocation failed, trying internal RAM...");
    bufSize =
        SCREEN_WIDTH * SCREEN_HEIGHT / 10; // Smaller buffer for internal RAM
    disp_draw_buf = (lv_color_t *)heap_caps_aligned_alloc(
        16, bufSize * sizeof(uint16_t), // RGB565 = 2 bytes
        MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  }
#else
  bufSize = SCREEN_WIDTH * SCREEN_HEIGHT / 10;
  Serial.printf("Allocating LVGL buffer: %d bytes (internal RAM)\n",
                bufSize * sizeof(uint16_t)); // RGB565 = 2 bytes
  disp_draw_buf = (lv_color_t *)heap_caps_aligned_alloc(
      16, bufSize * sizeof(uint16_t),
      MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT); // RGB565 = 2 bytes
#endif

  if (!disp_draw_buf) {
    Serial.println("ERROR: LVGL buffer allocation failed!");
    while (1)
      delay(1000); // Halt - this is fatal
  }

  Serial.printf("✓ LVGL buffer allocated: %d bytes\n",
                bufSize * sizeof(uint16_t)); // RGB565 = 2 bytes

  // FORCE Display Color Format to RGB565
  lv_display_set_color_format(display, LV_COLOR_FORMAT_RGB565);
  Serial.printf("Display Color Format set to: %d (RGB565=%d)\n",
                lv_display_get_color_format(display), LV_COLOR_FORMAT_RGB565);

  // Set display buffers using LVGL 9 API - FULL mode to avoid stripe artifacts
  lv_display_set_buffers(display, disp_draw_buf, NULL,
                         bufSize * sizeof(uint16_t), // RGB565 = 2 bytes
                         LV_DISPLAY_RENDER_MODE_FULL);

  Serial.println("✓ LVGL 9 Display registered");

#ifndef DISABLE_TOUCH
  // Initialize touch driver using LVGL 9 API
  lv_indev_t *indev_drv = lv_indev_create();
  lv_indev_set_type(indev_drv, LV_INDEV_TYPE_POINTER);
  lv_indev_set_read_cb(indev_drv, my_touchpad_read);

  Serial.println("✓ LVGL 9 Touch driver registered");
#else
  Serial.println(
      "! TOUCH DISABLED via DISABLE_TOUCH flag (Required for SD Card usage)");
#endif
  Serial.println("LVGL 9 initialized with Arduino_GFX");
}

#endif // USE_ARDUINO_GFX
