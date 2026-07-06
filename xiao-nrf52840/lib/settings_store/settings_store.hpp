#pragma once

#include <Arduino.h>

#include "settings_core.hpp"

namespace xiao_round {

using DeviceSettings = settings_core::DeviceSettings;

class SettingsStore {
public:
  bool begin();
  DeviceSettings load() const;
  bool save(const DeviceSettings &settings);

private:
  bool ready = false;
};

} // namespace xiao_round
