#pragma once

#include <Arduino.h>

namespace waveshare_board::speaker {

constexpr uint8_t DEFAULT_VOLUME_PERCENT = 70;

enum class Sound : uint8_t {
  BellDing = 1,
  PlasticBicycleHorn = 2,
  RotatingBicycleBell = 3,
  SqueezeHorn = 5,
};

bool begin();
bool requestPlay(Sound sound,
                 uint8_t volumePercent = DEFAULT_VOLUME_PERCENT);
bool isSupported(Sound sound);

} // namespace waveshare_board::speaker
