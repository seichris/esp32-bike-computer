#include "settings_store.hpp"

#include <Adafruit_LittleFS.h>
#include <InternalFileSystem.h>
#include <stdlib.h>
#include <string.h>

using namespace Adafruit_LittleFS_Namespace;

namespace xiao_round {
namespace {

constexpr const char *SETTINGS_FILE = "/bike_settings.txt";
constexpr uint8_t MIN_BRIGHTNESS_PERCENT = 5;
constexpr uint8_t MAX_BRIGHTNESS_PERCENT = 100;

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
  if (value < MIN_BRIGHTNESS_PERCENT) {
    return MIN_BRIGHTNESS_PERCENT;
  }
  if (value > MAX_BRIGHTNESS_PERCENT) {
    return MAX_BRIGHTNESS_PERCENT;
  }
  return static_cast<uint8_t>(value);
}

bool parseLongSetting(const char *buffer, const char *key, long &out) {
  const char *keyPosition = strstr(buffer, key);
  if (keyPosition == nullptr) {
    return false;
  }
  const char *valueStart = keyPosition + strlen(key);
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
  const char *keyPosition = strstr(buffer, key);
  if (keyPosition == nullptr) {
    return false;
  }
  const char *valueStart = keyPosition + strlen(key);
  char *end = nullptr;
  const unsigned long value = strtoul(valueStart, &end, 10);
  if (end == valueStart) {
    return false;
  }
  out = value;
  return true;
}

} // namespace

bool SettingsStore::begin() {
  ready = InternalFS.begin();
  Serial.print("SettingsStore: ");
  Serial.println(ready ? "ready" : "unavailable");
  return ready;
}

DeviceSettings SettingsStore::load() const {
  DeviceSettings settings;
  if (!ready) {
    return settings;
  }

  File file(InternalFS);
  if (!file.open(SETTINGS_FILE, FILE_O_READ)) {
    return settings;
  }

  char buffer[256] = {};
  const int readLen = file.read(buffer, sizeof(buffer) - 1);
  file.close();
  if (readLen <= 0) {
    return settings;
  }
  buffer[readLen] = '\0';

  const char *brightnessKey = strstr(buffer, "brightness=");
  if (brightnessKey != nullptr) {
    settings.brightnessPercent =
        clampBrightness(strtol(brightnessKey + strlen("brightness="), nullptr,
                               10));
  }

  long value = 0;
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
  return settings;
}

bool SettingsStore::save(const DeviceSettings &settings) {
  if (!ready) {
    return false;
  }

  if (InternalFS.exists(SETTINGS_FILE)) {
    InternalFS.remove(SETTINGS_FILE);
  }

  File file(InternalFS);
  if (!file.open(SETTINGS_FILE, FILE_O_WRITE)) {
    Serial.println("SettingsStore: failed to open settings for write");
    return false;
  }

  char buffer[256];
  const int formatLen = snprintf(
      buffer, sizeof(buffer),
      "brightness=%u\n"
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
      clampBrightness(settings.brightnessPercent),
      settings.mapSettings.minPolygonSize,
      settings.mapSettings.detailLevel, settings.mapSettings.routeLineWidth,
      settings.mapSettings.displayRotation, settings.mapSettings.mapRotationMode,
      settings.mapSettings.zoomLevel,
      static_cast<unsigned long>(settings.mapSettings.visibilityMask),
      settings.mapSettings.streetLineWidthBoost,
      settings.mapSettings.positionMarkerScale,
      settings.mapSettings.tapToSwitchScreens);
  if (formatLen <= 0 || static_cast<size_t>(formatLen) >= sizeof(buffer)) {
    file.close();
    Serial.println("SettingsStore: formatted settings too large");
    return false;
  }
  const size_t written = file.write(buffer, static_cast<size_t>(formatLen));
  file.close();
  return written == static_cast<size_t>(formatLen);
}

} // namespace xiao_round
