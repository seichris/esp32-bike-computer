#include "settings_core.hpp"

#include "power_core.hpp"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace xiao_round {
namespace settings_core {
namespace {

template <typename T> T clampValue(T value, T minValue, T maxValue) {
  if (value < minValue) {
    return minValue;
  }
  if (value > maxValue) {
    return maxValue;
  }
  return value;
}

uint8_t clampBrightness(long value) {
  if (value < power_core::MIN_TARGET_BRIGHTNESS_PERCENT) {
    return power_core::MIN_TARGET_BRIGHTNESS_PERCENT;
  }
  return power_core::clampTargetBrightness(static_cast<uint16_t>(value));
}

uint16_t clampBatteryScale(long value) {
  if (value < power_core::MIN_BATTERY_SCALE_PERMILLE) {
    return power_core::MIN_BATTERY_SCALE_PERMILLE;
  }
  return power_core::clampBatteryScale(static_cast<uint32_t>(value));
}

const char *findLineSettingValue(const char *buffer, const char *key) {
  if (buffer == nullptr || key == nullptr) {
    return nullptr;
  }

  const size_t keyLen = strlen(key);
  const char *cursor = buffer;
  while (*cursor != '\0') {
    if (strncmp(cursor, key, keyLen) == 0) {
      return cursor + keyLen;
    }
    const char *nextLine = strchr(cursor, '\n');
    if (nextLine == nullptr) {
      return nullptr;
    }
    cursor = nextLine + 1;
  }
  return nullptr;
}

bool parseLongSetting(const char *buffer, const char *key, long &out) {
  const char *valueStart = findLineSettingValue(buffer, key);
  if (valueStart == nullptr) {
    return false;
  }
  char *end = nullptr;
  const long value = strtol(valueStart, &end, 10);
  if (end == valueStart) {
    return false;
  }
  out = value;
  return true;
}

bool parseUnsignedLongSetting(const char *buffer, const char *key,
                              unsigned long &out) {
  const char *valueStart = findLineSettingValue(buffer, key);
  if (valueStart == nullptr) {
    return false;
  }
  char *end = nullptr;
  const unsigned long value = strtoul(valueStart, &end, 10);
  if (end == valueStart) {
    return false;
  }
  out = value;
  return true;
}

} // namespace

DeviceSettings parseSettingsText(const char *buffer) {
  DeviceSettings settings;
  if (buffer == nullptr || *buffer == '\0') {
    return settings;
  }

  long value = 0;
  if (parseLongSetting(buffer, "brightness=", value)) {
    settings.brightnessPercent = clampBrightness(value);
  }
  if (parseLongSetting(buffer, "min_polygon=", value)) {
    settings.mapSettings.minPolygonSize =
        static_cast<uint8_t>(clampValue<long>(value, 0, 50));
  }
  if (parseLongSetting(buffer, "detail=", value)) {
    settings.mapSettings.detailLevel =
        static_cast<uint8_t>(clampValue<long>(value, 0, 2));
  }
  if (parseLongSetting(buffer, "route_width=", value)) {
    settings.mapSettings.routeLineWidth =
        static_cast<uint8_t>(clampValue<long>(value, 2, 48));
  }
  if (parseLongSetting(buffer, "display_rotation=", value)) {
    settings.mapSettings.displayRotation =
        static_cast<uint8_t>(clampValue<long>(value, 0, 3));
  }
  if (parseLongSetting(buffer, "map_rotation=", value)) {
    settings.mapSettings.mapRotationMode =
        static_cast<uint8_t>(clampValue<long>(value, 0, 1));
  }
  if (parseLongSetting(buffer, "zoom=", value)) {
    settings.mapSettings.zoomLevel =
        static_cast<uint8_t>(clampValue<long>(value, 0, 5));
  }
  unsigned long unsignedValue = 0;
  if (parseUnsignedLongSetting(buffer, "visibility=", unsignedValue)) {
    settings.mapSettings.visibilityMask = static_cast<uint32_t>(unsignedValue);
  }
  if (parseLongSetting(buffer, "street_boost=", value)) {
    settings.mapSettings.streetLineWidthBoost =
        static_cast<uint8_t>(clampValue<long>(value, 0, 24));
  }
  if (parseLongSetting(buffer, "marker_scale=", value)) {
    settings.mapSettings.positionMarkerScale =
        static_cast<uint8_t>(clampValue<long>(value, 1, 5));
  }
  if (parseLongSetting(buffer, "tap_switch=", value)) {
    settings.mapSettings.tapToSwitchScreens = value != 0 ? 1 : 0;
  }
  if (parseLongSetting(buffer, "battery_scale_permille=", value)) {
    settings.batteryScalePermille = clampBatteryScale(value);
  }
  return settings;
}

size_t formatSettingsText(const DeviceSettings &settings, char *buffer,
                          size_t bufferSize) {
  if (buffer == nullptr || bufferSize == 0) {
    return 0;
  }

  const int formatLen = snprintf(
      buffer, bufferSize,
      "brightness=%u\n"
      "battery_scale_permille=%u\n"
      "min_polygon=%u\n"
      "detail=%u\n"
      "route_width=%u\n"
      "display_rotation=%u\n"
      "map_rotation=%u\n"
      "zoom=%u\n"
      "visibility=%lu\n"
      "street_boost=%u\n"
      "marker_scale=%u\n"
      "tap_switch=%u\n",
      power_core::clampTargetBrightness(settings.brightnessPercent),
      power_core::clampBatteryScale(settings.batteryScalePermille),
      settings.mapSettings.minPolygonSize,
      settings.mapSettings.detailLevel, settings.mapSettings.routeLineWidth,
      settings.mapSettings.displayRotation, settings.mapSettings.mapRotationMode,
      settings.mapSettings.zoomLevel,
      static_cast<unsigned long>(settings.mapSettings.visibilityMask),
      settings.mapSettings.streetLineWidthBoost,
      settings.mapSettings.positionMarkerScale,
      settings.mapSettings.tapToSwitchScreens);
  if (formatLen <= 0 || static_cast<size_t>(formatLen) >= bufferSize) {
    buffer[0] = '\0';
    return 0;
  }
  return static_cast<size_t>(formatLen);
}

} // namespace settings_core
} // namespace xiao_round
