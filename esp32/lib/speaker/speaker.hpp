#pragma once

#include <Arduino.h>

namespace waveshare_board::speaker {

enum class Sound : uint8_t {
  BellDing = 1,
  PlasticBicycleHorn = 2,
  RotatingBicycleBell = 3,
  SqueezeHorn = 5,
};

bool begin();
bool requestPlay(Sound sound);
bool isSupported(Sound sound);

} // namespace waveshare_board::speaker
