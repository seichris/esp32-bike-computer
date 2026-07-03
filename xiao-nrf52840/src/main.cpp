#include <Arduino.h>
#include <Adafruit_TinyUSB.h>

#include "ble_navigation.hpp"
#include "diagnostics.hpp"
#include "display_round.hpp"
#include "idle_sleep.hpp"
#include "map_lite.hpp"
#include "power_manager.hpp"
#include "rtc_pcf8563.hpp"
#include "serial_simulator.hpp"
#include "settings_store.hpp"
#include "ui_round.hpp"

namespace {

xiao_round::DisplayRound display;
xiao_round::BLENavigationServer &bleNav = xiao_round::bleNavigationServer;
xiao_round::RoundUi roundUi;
xiao_round::Diagnostics diagnostics;
xiao_round::SettingsStore settingsStore;
xiao_round::PowerManager powerManager;
xiao_round::IdleSleepManager idleSleepManager;
xiao_round::MapLite mapLite;
xiao_round::SerialSimulator serialSimulator;
uint32_t lastHeartbeatMs = 0;
uint32_t heartbeatCount = 0;
uint32_t lastSettingsSaveAttemptMs = 0;
constexpr uint32_t SETTINGS_SAVE_DEBOUNCE_MS = 2000;

void setupSerial() {
  Serial.begin(SERIAL_BAUD);
  const uint32_t startMs = millis();
  while (!Serial && millis() - startMs < 2000) {
    delay(10);
  }
}

void setupLed() {
#ifdef LED_BUILTIN
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);
#endif
}

void toggleLed() {
#ifdef LED_BUILTIN
  digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN));
#endif
}

} // namespace

void setup() {
  setupSerial();
  setupLed();

  Serial.println();
  Serial.println("XIAO nRF52840 Round Display bike computer skeleton");
  Serial.println("Milestone 1: repo firmware skeleton");

  settingsStore.begin();
  const xiao_round::DeviceSettings deviceSettings = settingsStore.load();
  bleNav.setInitialSettings(deviceSettings.mapSettings);

  if (!display.begin()) {
    Serial.println("DisplayRound: init failed");
  }
  powerManager.begin(display, deviceSettings.brightnessPercent,
                     deviceSettings.batteryScalePermille);
  xiao_round::rtc::begin();
  display.drawBootScreen();
  display.drawStatus("BikeComputer", "Waiting for BLE");

  if (!bleNav.begin("BikeComputer-XIAO")) {
    Serial.println("BLE: init failed");
    display.drawStatus("BikeComputer", "BLE init failed");
  }

  roundUi.begin(display);
  diagnostics.begin();
  serialSimulator.begin(bleNav, powerManager, mapLite, roundUi);
  mapLite.begin();
}

void loop() {
  const uint32_t now = millis();
  serialSimulator.update();
  bleNav.process();
  uint8_t requestedBrightness = 0;
  if (bleNav.takeBrightnessCommand(requestedBrightness)) {
    powerManager.setTargetBrightness(requestedBrightness);
  }
  powerManager.update(bleNav, roundUi.lastInteractionMs());
  roundUi.update(bleNav, powerManager, mapLite);
  const bike_ble::GpsPosition &gps = bleNav.currentGps();
  mapLite.updateForGps(gps.latMicrodegrees, gps.lonMicrodegrees, now);
  diagnostics.update(bleNav, powerManager, roundUi, idleSleepManager, mapLite);
  if (serialSimulator.takeDiagnosticRequest()) {
    diagnostics.logNow("serial", bleNav, powerManager, roundUi,
                       idleSleepManager, mapLite);
  }

  const bool settingsWriteDue =
      ((bleNav.hasUnpersistedSettings() &&
        now - bleNav.lastSettingsChangeMs() >= SETTINGS_SAVE_DEBOUNCE_MS) ||
       (powerManager.hasUnpersistedBrightness() &&
        now - powerManager.lastBrightnessChangeMs() >=
            SETTINGS_SAVE_DEBOUNCE_MS) ||
       (powerManager.hasUnpersistedPowerCalibration() &&
        now - powerManager.lastPowerCalibrationChangeMs() >=
            SETTINGS_SAVE_DEBOUNCE_MS)) &&
      now - lastSettingsSaveAttemptMs >= SETTINGS_SAVE_DEBOUNCE_MS;
  if (settingsWriteDue) {
    lastSettingsSaveAttemptMs = now;
    xiao_round::DeviceSettings settings;
    settings.brightnessPercent = powerManager.targetBrightness();
    settings.batteryScalePermille = powerManager.batteryCalibrationPermille();
    settings.mapSettings = bleNav.currentSettings();
    if (settingsStore.save(settings)) {
      bleNav.markSettingsPersisted();
      powerManager.markBrightnessPersisted();
      powerManager.markPowerCalibrationPersisted();
      Serial.println("SettingsStore: device settings saved");
    }
  }

  if (now - lastHeartbeatMs >= 1000) {
    lastHeartbeatMs = now;
    heartbeatCount++;
    toggleLed();

    Serial.print("heartbeat=");
    Serial.print(heartbeatCount);
    Serial.print(" uptime_ms=");
    Serial.println(now);
  }

  idleSleepManager.update(bleNav, powerManager, settingsWriteDue);
}
