#include "power_manager.hpp"

#include "round_display_pins.hpp"

namespace xiao_round {
namespace {

constexpr uint32_t BATTERY_SAMPLE_INTERVAL_MS = 5000;
constexpr uint32_t POWER_LOG_INTERVAL_MS = 15000;
constexpr uint32_t AUTO_DIM_AFTER_MS = 30000;
constexpr uint32_t SCREEN_OFF_AFTER_MS = 120000;
constexpr uint8_t DIM_BRIGHTNESS_PERCENT = 20;
constexpr uint8_t MIN_TARGET_BRIGHTNESS_PERCENT = 5;
constexpr uint16_t ADC_MAX_RAW = 4095;
constexpr uint16_t ADC_REFERENCE_MV = 3600;
constexpr uint8_t BATTERY_DIVIDER_NUMERATOR = 2;
constexpr uint8_t BATTERY_DIVIDER_DENOMINATOR = 1;
constexpr uint16_t BATTERY_EMPTY_MV = 3300;
constexpr uint16_t BATTERY_FULL_MV = 4200;
constexpr uint16_t BATTERY_LOW_MV = 3500;

uint8_t clampTargetBrightness(uint8_t value) {
  if (value < MIN_TARGET_BRIGHTNESS_PERCENT) {
    return MIN_TARGET_BRIGHTNESS_PERCENT;
  } else if (value > 100) {
    return 100;
  }
  return value;
}

uint8_t clampOutputBrightness(uint8_t value) {
  return value > 100 ? 100 : value;
}

uint8_t estimateBatteryPercent(uint16_t batteryMillivolts) {
  if (batteryMillivolts <= BATTERY_EMPTY_MV) {
    return 0;
  }
  if (batteryMillivolts >= BATTERY_FULL_MV) {
    return 100;
  }
  return static_cast<uint8_t>(
      ((batteryMillivolts - BATTERY_EMPTY_MV) * 100UL) /
      (BATTERY_FULL_MV - BATTERY_EMPTY_MV));
}

uint32_t maxTimestamp(uint32_t a, uint32_t b) { return a > b ? a : b; }

} // namespace

bool PowerManager::begin(DisplayRound &targetDisplay,
                         uint8_t requestedBrightnessPercent) {
  display = &targetDisplay;
  bootActivityMs = millis();
  targetBrightnessPercent = clampTargetBrightness(requestedBrightnessPercent);

  pinMode(pins::batteryAdc, INPUT);
  analogReadResolution(12);
  analogReference(AR_INTERNAL);
  analogSampleTime(40);
  analogOversampling(4);
  analogCalibrateOffset();

  sampleBattery(millis());
  applyBrightness(targetBrightnessPercent);
  Serial.println("PowerManager: initialized");
  return true;
}

bool PowerManager::setTargetBrightness(uint8_t brightnessPercent) {
  const uint8_t clamped = clampTargetBrightness(brightnessPercent);
  lastBrightnessChangeMsValue = millis();
  if (clamped == targetBrightnessPercent) {
    return false;
  }

  targetBrightnessPercent = clamped;
  brightnessDirty = true;
  autoDimmed = false;
  screenOff = false;
  applyBrightness(targetBrightnessPercent);
  Serial.print("Power: target brightness=");
  Serial.println(targetBrightnessPercent);
  return true;
}

void PowerManager::update(const BLENavigationServer &bleServer,
                          uint32_t userActivityMs) {
  const uint32_t now = millis();
  sampleBattery(now);
  updateBrightness(bleServer, userActivityMs, now);

  if (now - lastPowerLogMs >= POWER_LOG_INTERVAL_MS) {
    lastPowerLogMs = now;
    Serial.print("Power: battery_mv=");
    Serial.print(batteryStatus.batteryMillivolts);
    Serial.print(" raw=");
    Serial.print(batteryStatus.rawAdc);
    Serial.print(" pct=");
    Serial.print(batteryStatus.percent);
    Serial.print(" low=");
    Serial.print(batteryStatus.low);
    Serial.print(" brightness=");
    Serial.print(currentBrightnessPercent);
    Serial.print(" dim=");
    Serial.print(autoDimmed);
    Serial.print(" off=");
    Serial.println(screenOff);
  }
}

void PowerManager::sampleBattery(uint32_t now) {
  if (lastBatterySampleMs != 0 &&
      now - lastBatterySampleMs < BATTERY_SAMPLE_INTERVAL_MS) {
    return;
  }
  lastBatterySampleMs = now;

  uint32_t rawTotal = 0;
  constexpr uint8_t sampleCount = 8;
  for (uint8_t i = 0; i < sampleCount; i++) {
    rawTotal += analogRead(pins::batteryAdc);
    delay(1);
  }
  const uint16_t raw = static_cast<uint16_t>(rawTotal / sampleCount);
  const uint16_t pinMv =
      static_cast<uint16_t>((raw * static_cast<uint32_t>(ADC_REFERENCE_MV)) /
                            ADC_MAX_RAW);
  const uint16_t batteryMv = static_cast<uint16_t>(
      (pinMv * static_cast<uint32_t>(BATTERY_DIVIDER_NUMERATOR)) /
      BATTERY_DIVIDER_DENOMINATOR);

  batteryStatus.valid = raw > 0;
  batteryStatus.rawAdc = raw;
  batteryStatus.pinMillivolts = pinMv;
  batteryStatus.batteryMillivolts = batteryMv;
  batteryStatus.percent = estimateBatteryPercent(batteryMv);
  batteryStatus.low = batteryStatus.valid && batteryMv <= BATTERY_LOW_MV;
}

void PowerManager::updateBrightness(const BLENavigationServer &bleServer,
                                    uint32_t userActivityMs, uint32_t now) {
  const BLEDebugStats stats = bleServer.getDebugStats();
  uint32_t lastActivityMs = maxTimestamp(userActivityMs, lastBleActivityMs(stats));
  lastActivityMs = maxTimestamp(lastActivityMs, lastBrightnessChangeMsValue);
  if (lastActivityMs == 0) {
    lastActivityMs = bootActivityMs;
  }

  uint8_t desired = targetBrightnessPercent;
  screenOff = false;
  autoDimmed = false;

  if (!stats.connected && now - lastActivityMs >= SCREEN_OFF_AFTER_MS) {
    desired = 0;
    screenOff = true;
    autoDimmed = true;
  } else if (now - lastActivityMs >= AUTO_DIM_AFTER_MS) {
    desired = targetBrightnessPercent < DIM_BRIGHTNESS_PERCENT
                  ? targetBrightnessPercent
                  : DIM_BRIGHTNESS_PERCENT;
    autoDimmed = desired < targetBrightnessPercent;
  }

  if (desired != currentBrightnessPercent) {
    applyBrightness(desired);
  }
}

uint32_t PowerManager::lastBleActivityMs(const BLEDebugStats &stats) const {
  uint32_t lastActivity = maxTimestamp(stats.lastConnectMs, stats.lastAuthSuccessMs);
  lastActivity = maxTimestamp(lastActivity, stats.lastNavPacketMs);
  lastActivity = maxTimestamp(lastActivity, stats.lastRoutePacketMs);
  lastActivity = maxTimestamp(lastActivity, stats.lastGpsPacketMs);
  lastActivity = maxTimestamp(lastActivity, stats.lastSettingsPacketMs);
  return lastActivity;
}

void PowerManager::applyBrightness(uint8_t brightnessPercent) {
  currentBrightnessPercent = clampOutputBrightness(brightnessPercent);
  if (display != nullptr) {
    display->setBrightness(currentBrightnessPercent);
  }
}

} // namespace xiao_round
