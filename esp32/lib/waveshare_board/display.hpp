/**
 * @file display.hpp
 * @brief CO5300 display constants for the Waveshare AMOLED board.
 */

#pragma once

#include <Arduino.h>

namespace waveshare_board::display {

constexpr uint16_t LOGICAL_WIDTH = 466;
constexpr uint16_t LOGICAL_HEIGHT = 466;
constexpr uint16_t ACTIVE_WIDTH = 466;
constexpr uint16_t ACTIVE_HEIGHT = 466;

// Vendor Waveshare Arduino examples use:
// Arduino_CO5300(..., 466, 466, 6, 0, 0, 0)
// The ESP-IDF BSP applies the same effective panel gap with
// esp_lcd_panel_set_gap(panel_handle, 6, 0).
constexpr uint8_t ARDUINO_CO5300_COL_OFFSET1 = 6;
constexpr uint8_t ARDUINO_CO5300_ROW_OFFSET1 = 0;
constexpr uint8_t ARDUINO_CO5300_COL_OFFSET2 = 0;
constexpr uint8_t ARDUINO_CO5300_ROW_OFFSET2 = 0;

constexpr uint8_t ROTATION_0 = 0;
constexpr uint8_t ROTATION_90 = 1;
constexpr uint8_t MAX_SUPPORTED_ROTATION = ROTATION_90;

constexpr uint8_t CO5300_CASET = 0x2A;
constexpr uint8_t CO5300_PASET = 0x2B;
constexpr uint8_t CO5300_MADCTL = 0x36;
constexpr uint8_t CO5300_MADCTL_MV = 0x20;
constexpr uint8_t CO5300_MADCTL_X_FLIP = 0x02;
constexpr uint8_t CO5300_MADCTL_RGB = 0x00;
constexpr uint8_t CO5300_MADCTL_ROTATION_0 = CO5300_MADCTL_RGB;
constexpr uint8_t CO5300_MADCTL_ROTATION_90 =
    CO5300_MADCTL_RGB | CO5300_MADCTL_MV | CO5300_MADCTL_X_FLIP;

#ifdef WAVESHARE_ENABLE_EXPERIMENTAL_90_ROTATION
constexpr bool EXPERIMENTAL_90_ROTATION_ENABLED = true;
#else
constexpr bool EXPERIMENTAL_90_ROTATION_ENABLED = false;
#endif

} // namespace waveshare_board::display
