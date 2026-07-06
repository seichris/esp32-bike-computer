#pragma once

#include <Arduino.h>

#include "ble_navigation.hpp"
#include "display_round.hpp"

namespace xiao_round {

struct BatteryStatus {
  bool valid = false;
  uint16_t rawAdc = 0;
  uint16_t pinMillivolts = 0;
  uint16_t batteryMillivolts = 0;
  uint8_t percent = 0;
  bool low = false;
};

class PowerManager {
public:
  bool begin(DisplayRound &display, uint8_t targetBrightnessPercent,
             uint16_t batteryScalePermille);
  void update(const BLENavigationServer &bleServer, uint32_t userActivityMs);

  const BatteryStatus &battery() const { return batteryStatus; }
  uint8_t currentBrightness() const { return currentBrightnessPercent; }
  uint8_t targetBrightness() const { return targetBrightnessPercent; }
  uint16_t batteryCalibrationPermille() const {
    return batteryScalePermille;
  }
  bool isAutoDimmed() const { return autoDimmed; }
  bool isScreenOff() const { return screenOff; }
  bool setTargetBrightness(uint8_t brightnessPercent);
  bool calibrateBatteryMillivolts(uint16_t measuredBatteryMillivolts);
  bool hasUnpersistedBrightness() const { return brightnessDirty; }
  bool hasUnpersistedPowerCalibration() const { return calibrationDirty; }
  uint32_t lastBrightnessChangeMs() const { return lastBrightnessChangeMsValue; }
  uint32_t lastPowerCalibrationChangeMs() const {
    return lastCalibrationChangeMsValue;
  }
  void markBrightnessPersisted() { brightnessDirty = false; }
  void markPowerCalibrationPersisted() { calibrationDirty = false; }

private:
  void sampleBattery(uint32_t now);
  void updateBrightness(const BLENavigationServer &bleServer,
                        uint32_t userActivityMs, uint32_t now);
  void applyBrightness(uint8_t brightnessPercent);

  DisplayRound *display = nullptr;
  BatteryStatus batteryStatus;
  uint8_t targetBrightnessPercent = 100;
  uint8_t currentBrightnessPercent = 100;
  uint16_t batteryScalePermille = 2000;
  bool autoDimmed = false;
  bool screenOff = false;
  uint32_t bootActivityMs = 0;
  uint32_t lastBrightnessChangeMsValue = 0;
  uint32_t lastBatterySampleMs = 0;
  uint32_t lastPowerLogMs = 0;
  uint32_t lastCalibrationChangeMsValue = 0;
  bool brightnessDirty = false;
  bool calibrationDirty = false;
};

} // namespace xiao_round
