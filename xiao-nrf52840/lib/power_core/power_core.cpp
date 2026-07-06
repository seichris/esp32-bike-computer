#include "power_core.hpp"

namespace xiao_round {
namespace power_core {
namespace {

uint32_t maxTimestamp(uint32_t a, uint32_t b) { return a > b ? a : b; }

uint32_t minElapsed(uint32_t a, uint32_t b) { return a < b ? a : b; }

uint32_t elapsedSinceLatestActivityMs(const ActivityTimestamps &activity,
                                      uint32_t nowMs) {
  uint32_t elapsed = nowMs - activity.bootActivityMs;
  elapsed = minElapsed(elapsed, nowMs - activity.userActivityMs);
  elapsed = minElapsed(elapsed, nowMs - activity.brightnessChangeMs);
  elapsed = minElapsed(elapsed, nowMs - activity.bleConnectMs);
  elapsed = minElapsed(elapsed, nowMs - activity.bleDisconnectMs);
  elapsed = minElapsed(elapsed, nowMs - activity.bleAuthSuccessMs);
  elapsed = minElapsed(elapsed, nowMs - activity.bleNavPacketMs);
  elapsed = minElapsed(elapsed, nowMs - activity.bleRoutePacketMs);
  elapsed = minElapsed(elapsed, nowMs - activity.bleRouteDuplicateMs);
  elapsed = minElapsed(elapsed, nowMs - activity.bleGpsPacketMs);
  elapsed = minElapsed(elapsed, nowMs - activity.bleSettingsPacketMs);
  elapsed = minElapsed(elapsed, nowMs - activity.bleDeviceCommandMs);
  return elapsed;
}

} // namespace

uint8_t clampTargetBrightness(uint16_t value) {
  if (value < MIN_TARGET_BRIGHTNESS_PERCENT) {
    return MIN_TARGET_BRIGHTNESS_PERCENT;
  }
  if (value > MAX_TARGET_BRIGHTNESS_PERCENT) {
    return MAX_TARGET_BRIGHTNESS_PERCENT;
  }
  return static_cast<uint8_t>(value);
}

uint8_t clampOutputBrightness(uint16_t value) {
  return value > MAX_TARGET_BRIGHTNESS_PERCENT
             ? MAX_TARGET_BRIGHTNESS_PERCENT
             : static_cast<uint8_t>(value);
}

uint16_t clampBatteryScale(uint32_t scalePermille) {
  if (scalePermille < MIN_BATTERY_SCALE_PERMILLE) {
    return MIN_BATTERY_SCALE_PERMILLE;
  }
  if (scalePermille > MAX_BATTERY_SCALE_PERMILLE) {
    return MAX_BATTERY_SCALE_PERMILLE;
  }
  return static_cast<uint16_t>(scalePermille);
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

uint16_t batteryMillivoltsFromPin(uint16_t pinMillivolts,
                                  uint16_t scalePermille) {
  const uint32_t batteryMillivolts =
      (static_cast<uint32_t>(pinMillivolts) *
       clampBatteryScale(scalePermille)) /
      1000UL;
  return batteryMillivolts > UINT16_MAX
             ? UINT16_MAX
             : static_cast<uint16_t>(batteryMillivolts);
}

bool isValidCalibrationMeasurement(uint16_t measuredBatteryMillivolts) {
  return measuredBatteryMillivolts >= MIN_CALIBRATION_BATTERY_MV &&
         measuredBatteryMillivolts <= MAX_CALIBRATION_BATTERY_MV;
}

bool computeCalibrationScale(uint16_t measuredBatteryMillivolts,
                             uint16_t pinMillivolts,
                             uint16_t &scalePermille) {
  if (!isValidCalibrationMeasurement(measuredBatteryMillivolts) ||
      pinMillivolts == 0) {
    return false;
  }

  const uint32_t computedScale =
      (static_cast<uint32_t>(measuredBatteryMillivolts) * 1000UL +
       (pinMillivolts / 2U)) /
      pinMillivolts;
  scalePermille = clampBatteryScale(computedScale);
  return true;
}

uint32_t latestActivityMs(const ActivityTimestamps &activity) {
  uint32_t latest = activity.bootActivityMs;
  latest = maxTimestamp(latest, activity.userActivityMs);
  latest = maxTimestamp(latest, activity.brightnessChangeMs);
  latest = maxTimestamp(latest, activity.bleConnectMs);
  latest = maxTimestamp(latest, activity.bleDisconnectMs);
  latest = maxTimestamp(latest, activity.bleAuthSuccessMs);
  latest = maxTimestamp(latest, activity.bleNavPacketMs);
  latest = maxTimestamp(latest, activity.bleRoutePacketMs);
  latest = maxTimestamp(latest, activity.bleRouteDuplicateMs);
  latest = maxTimestamp(latest, activity.bleGpsPacketMs);
  latest = maxTimestamp(latest, activity.bleSettingsPacketMs);
  latest = maxTimestamp(latest, activity.bleDeviceCommandMs);
  return latest;
}

BrightnessDecision chooseBrightness(uint8_t targetBrightnessPercent,
                                    bool bleConnected,
                                    const ActivityTimestamps &activity,
                                    uint32_t nowMs) {
  BrightnessDecision decision;
  const uint8_t target = clampTargetBrightness(targetBrightnessPercent);
  decision.outputBrightnessPercent = target;

  const uint32_t inactiveMs = elapsedSinceLatestActivityMs(activity, nowMs);
  if (!bleConnected && inactiveMs >= SCREEN_OFF_AFTER_MS) {
    decision.outputBrightnessPercent = 0;
    decision.screenOff = true;
    decision.autoDimmed = true;
    return decision;
  }

  if (inactiveMs >= AUTO_DIM_AFTER_MS) {
    decision.outputBrightnessPercent =
        target < DIM_BRIGHTNESS_PERCENT ? target : DIM_BRIGHTNESS_PERCENT;
    decision.autoDimmed = decision.outputBrightnessPercent < target;
  }

  return decision;
}

} // namespace power_core
} // namespace xiao_round
