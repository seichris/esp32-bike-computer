#pragma once

#include <Arduino.h>

namespace xiao_round::pins {

constexpr uint8_t batteryAdc = D0;
constexpr uint8_t lcdCs = D1;
constexpr uint8_t sdCs = D2;
constexpr uint8_t lcdDc = D3;
constexpr uint8_t i2cSda = D4;
constexpr uint8_t i2cScl = D5;
constexpr uint8_t backlight = D6;
constexpr uint8_t touchInt = D7;
constexpr uint8_t spiSck = D8;
constexpr uint8_t spiMiso = D9;
constexpr uint8_t spiMosi = D10;

} // namespace xiao_round::pins
