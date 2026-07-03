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
  bool begin(DisplayRound &display, uint8_t targetBrightnessPercent);
  void update(const BLENavigationServer &bleServer, uint32_t userActivityMs);

  const BatteryStatus &battery() const { return batteryStatus; }
  uint8_t currentBrightness() const { return currentBrightnessPercent; }
  uint8_t targetBrightness() const { return targetBrightnessPercent; }
  bool isAutoDimmed() const { return autoDimmed; }
  bool isScreenOff() const { return screenOff; }
  bool setTargetBrightness(uint8_t brightnessPercent);
  bool hasUnpersistedBrightness() const { return brightnessDirty; }
  uint32_t lastBrightnessChangeMs() const { return lastBrightnessChangeMsValue; }
  void markBrightnessPersisted() { brightnessDirty = false; }

private:
  void sampleBattery(uint32_t now);
  void updateBrightness(const BLENavigationServer &bleServer,
                        uint32_t userActivityMs, uint32_t now);
  uint32_t lastBleActivityMs(const BLEDebugStats &stats) const;
  void applyBrightness(uint8_t brightnessPercent);

  DisplayRound *display = nullptr;
  BatteryStatus batteryStatus;
  uint8_t targetBrightnessPercent = 100;
  uint8_t currentBrightnessPercent = 100;
  bool autoDimmed = false;
  bool screenOff = false;
  uint32_t bootActivityMs = 0;
  uint32_t lastBrightnessChangeMsValue = 0;
  uint32_t lastBatterySampleMs = 0;
  uint32_t lastPowerLogMs = 0;
  bool brightnessDirty = false;
};

} // namespace xiao_round
