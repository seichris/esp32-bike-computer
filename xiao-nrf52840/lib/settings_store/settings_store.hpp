#pragma once

#include <Arduino.h>

#include "ble_protocol.hpp"

namespace xiao_round {

struct DeviceSettings {
  uint8_t brightnessPercent = 100;
  bike_ble::MapRenderSettings mapSettings;
};

class SettingsStore {
public:
  bool begin();
  DeviceSettings load() const;
  bool save(const DeviceSettings &settings);

private:
  bool ready = false;
};

} // namespace xiao_round
