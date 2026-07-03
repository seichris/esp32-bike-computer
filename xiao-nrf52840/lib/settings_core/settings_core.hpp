#pragma once

#include <stddef.h>
#include <stdint.h>

#include "ble_protocol.hpp"

namespace xiao_round {
namespace settings_core {

struct DeviceSettings {
  uint8_t brightnessPercent = 100;
  uint16_t batteryScalePermille = 2000;
  bike_ble::MapRenderSettings mapSettings;
};

DeviceSettings parseSettingsText(const char *buffer);
size_t formatSettingsText(const DeviceSettings &settings, char *buffer,
                          size_t bufferSize);

} // namespace settings_core
} // namespace xiao_round
