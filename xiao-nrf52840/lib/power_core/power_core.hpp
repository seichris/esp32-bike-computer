#pragma once

#include <stdint.h>

namespace xiao_round {
namespace power_core {

constexpr uint8_t MIN_TARGET_BRIGHTNESS_PERCENT = 5;
constexpr uint8_t MAX_TARGET_BRIGHTNESS_PERCENT = 100;
constexpr uint16_t DEFAULT_BATTERY_SCALE_PERMILLE = 2000;
constexpr uint16_t MIN_BATTERY_SCALE_PERMILLE = 1000;
constexpr uint16_t MAX_BATTERY_SCALE_PERMILLE = 4000;
constexpr uint16_t MIN_CALIBRATION_BATTERY_MV = 2500;
constexpr uint16_t MAX_CALIBRATION_BATTERY_MV = 4500;
constexpr uint16_t BATTERY_EMPTY_MV = 3300;
constexpr uint16_t BATTERY_FULL_MV = 4200;
constexpr uint16_t BATTERY_LOW_MV = 3500;
constexpr uint32_t AUTO_DIM_AFTER_MS = 30000;
constexpr uint32_t SCREEN_OFF_AFTER_MS = 120000;
constexpr uint8_t DIM_BRIGHTNESS_PERCENT = 20;

struct ActivityTimestamps {
  uint32_t userActivityMs = 0;
  uint32_t brightnessChangeMs = 0;
  uint32_t bootActivityMs = 0;
  uint32_t bleConnectMs = 0;
  uint32_t bleDisconnectMs = 0;
  uint32_t bleAuthSuccessMs = 0;
  uint32_t bleNavPacketMs = 0;
  uint32_t bleRoutePacketMs = 0;
  uint32_t bleRouteDuplicateMs = 0;
  uint32_t bleGpsPacketMs = 0;
  uint32_t bleSettingsPacketMs = 0;
  uint32_t bleDeviceCommandMs = 0;
};

struct BrightnessDecision {
  uint8_t outputBrightnessPercent = 0;
  bool autoDimmed = false;
  bool screenOff = false;
};

uint8_t clampTargetBrightness(uint16_t value);
uint8_t clampOutputBrightness(uint16_t value);
uint16_t clampBatteryScale(uint32_t scalePermille);
uint8_t estimateBatteryPercent(uint16_t batteryMillivolts);
uint16_t batteryMillivoltsFromPin(uint16_t pinMillivolts,
                                  uint16_t scalePermille);
bool isValidCalibrationMeasurement(uint16_t measuredBatteryMillivolts);
bool computeCalibrationScale(uint16_t measuredBatteryMillivolts,
                             uint16_t pinMillivolts,
                             uint16_t &scalePermille);
uint32_t latestActivityMs(const ActivityTimestamps &activity);
BrightnessDecision chooseBrightness(uint8_t targetBrightnessPercent,
                                    bool bleConnected,
                                    const ActivityTimestamps &activity,
                                    uint32_t nowMs);

} // namespace power_core
} // namespace xiao_round
