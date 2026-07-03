#include "power_manager.hpp"

#include "power_core.hpp"
#include "round_display_pins.hpp"

namespace xiao_round {
namespace {

constexpr uint32_t BATTERY_SAMPLE_INTERVAL_MS = 5000;
constexpr uint32_t POWER_LOG_INTERVAL_MS = 15000;
constexpr uint16_t ADC_MAX_RAW = 4095;
constexpr uint16_t ADC_REFERENCE_MV = 3600;

power_core::ActivityTimestamps activityFromBleStats(const BLEDebugStats &stats,
                                                    uint32_t userActivityMs,
                                                    uint32_t brightnessChangeMs,
                                                    uint32_t bootActivityMs) {
  power_core::ActivityTimestamps activity;
  activity.userActivityMs = userActivityMs;
  activity.brightnessChangeMs = brightnessChangeMs;
  activity.bootActivityMs = bootActivityMs;
  activity.bleConnectMs = stats.lastConnectMs;
  activity.bleDisconnectMs = stats.lastDisconnectMs;
  activity.bleAuthSuccessMs = stats.lastAuthSuccessMs;
  activity.bleNavPacketMs = stats.lastNavPacketMs;
  activity.bleRoutePacketMs = stats.lastRoutePacketMs;
  activity.bleRouteDuplicateMs = stats.lastRouteDuplicateMs;
  activity.bleGpsPacketMs = stats.lastGpsPacketMs;
  activity.bleSettingsPacketMs = stats.lastSettingsPacketMs;
  activity.bleDeviceCommandMs = stats.lastDeviceCommandMs;
  return activity;
}

} // namespace

bool PowerManager::begin(DisplayRound &targetDisplay,
                         uint8_t requestedBrightnessPercent,
                         uint16_t requestedBatteryScalePermille) {
  display = &targetDisplay;
  bootActivityMs = millis();
  targetBrightnessPercent =
      power_core::clampTargetBrightness(requestedBrightnessPercent);
  const uint16_t requestedScale =
      requestedBatteryScalePermille == 0
          ? power_core::DEFAULT_BATTERY_SCALE_PERMILLE
          : requestedBatteryScalePermille;
  batteryScalePermille = power_core::clampBatteryScale(requestedScale);

  pinMode(pins::batteryAdc, INPUT);
  analogReadResolution(12);
  analogReference(AR_INTERNAL);
  analogSampleTime(40);
  analogOversampling(4);
  analogCalibrateOffset();

  sampleBattery(millis());
  applyBrightness(targetBrightnessPercent);
  Serial.print("PowerManager: initialized battery_scale_permille=");
  Serial.println(batteryScalePermille);
  return true;
}

bool PowerManager::setTargetBrightness(uint8_t brightnessPercent) {
  const uint8_t clamped = power_core::clampTargetBrightness(brightnessPercent);
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

bool PowerManager::calibrateBatteryMillivolts(
    uint16_t measuredBatteryMillivolts) {
  if (!power_core::isValidCalibrationMeasurement(measuredBatteryMillivolts)) {
    Serial.println("Power: BATCAL expects measured millivolts 2500..4500");
    return false;
  }

  sampleBattery(millis());
  if (!batteryStatus.valid || batteryStatus.pinMillivolts == 0) {
    Serial.println("Power: BATCAL failed, battery ADC is not valid yet");
    return false;
  }

  uint16_t nextScale = batteryScalePermille;
  if (!power_core::computeCalibrationScale(measuredBatteryMillivolts,
                                           batteryStatus.pinMillivolts,
                                           nextScale)) {
    Serial.println("Power: BATCAL failed, calibration scale is invalid");
    return false;
  }
  batteryScalePermille = nextScale;
  batteryStatus.batteryMillivolts = power_core::batteryMillivoltsFromPin(
      batteryStatus.pinMillivolts, batteryScalePermille);
  batteryStatus.percent =
      power_core::estimateBatteryPercent(batteryStatus.batteryMillivolts);
  batteryStatus.low =
      batteryStatus.valid &&
      batteryStatus.batteryMillivolts <= power_core::BATTERY_LOW_MV;
  calibrationDirty = true;
  lastCalibrationChangeMsValue = millis();

  Serial.print("Power: battery calibration measured_mv=");
  Serial.print(measuredBatteryMillivolts);
  Serial.print(" pin_mv=");
  Serial.print(batteryStatus.pinMillivolts);
  Serial.print(" scale_permille=");
  Serial.println(batteryScalePermille);
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
    Serial.print(" scale_permille=");
    Serial.print(batteryScalePermille);
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
  const uint16_t batteryMv =
      power_core::batteryMillivoltsFromPin(pinMv, batteryScalePermille);

  batteryStatus.valid = raw > 0;
  batteryStatus.rawAdc = raw;
  batteryStatus.pinMillivolts = pinMv;
  batteryStatus.batteryMillivolts = batteryMv;
  batteryStatus.percent = power_core::estimateBatteryPercent(batteryMv);
  batteryStatus.low =
      batteryStatus.valid && batteryMv <= power_core::BATTERY_LOW_MV;
}

void PowerManager::updateBrightness(const BLENavigationServer &bleServer,
                                    uint32_t userActivityMs, uint32_t now) {
  const BLEDebugStats stats = bleServer.getDebugStats();
  const power_core::BrightnessDecision decision = power_core::chooseBrightness(
      targetBrightnessPercent, stats.connected,
      activityFromBleStats(stats, userActivityMs, lastBrightnessChangeMsValue,
                           bootActivityMs),
      now);
  const uint8_t desired = decision.outputBrightnessPercent;
  screenOff = decision.screenOff;
  autoDimmed = decision.autoDimmed;

  if (desired != currentBrightnessPercent) {
    applyBrightness(desired);
  }
}

void PowerManager::applyBrightness(uint8_t brightnessPercent) {
  currentBrightnessPercent =
      power_core::clampOutputBrightness(brightnessPercent);
  if (display != nullptr) {
    display->setBrightness(currentBrightnessPercent);
  }
}

} // namespace xiao_round
