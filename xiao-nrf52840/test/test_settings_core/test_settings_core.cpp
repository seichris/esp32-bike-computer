#include <unity.h>

#include "settings_core.hpp"

#include <string.h>

namespace {

void testDefaultsWhenSettingsTextIsMissing() {
  const xiao_round::settings_core::DeviceSettings settings =
      xiao_round::settings_core::parseSettingsText(nullptr);

  TEST_ASSERT_EQUAL_UINT8(100, settings.brightnessPercent);
  TEST_ASSERT_EQUAL_UINT16(2000, settings.batteryScalePermille);
}

void testParsesAndClampsBatteryBrightnessAndMapSettings() {
  const char text[] =
      "brightness=1\n"
      "battery_scale_permille=9999\n"
      "min_polygon=99\n"
      "detail=4\n"
      "route_width=1\n"
      "display_rotation=9\n"
      "map_rotation=7\n"
      "zoom=9\n"
      "visibility=3735928559\n"
      "street_boost=99\n"
      "marker_scale=0\n"
      "tap_switch=7\n";

  const xiao_round::settings_core::DeviceSettings settings =
      xiao_round::settings_core::parseSettingsText(text);

  TEST_ASSERT_EQUAL_UINT8(5, settings.brightnessPercent);
  TEST_ASSERT_EQUAL_UINT16(4000, settings.batteryScalePermille);
  TEST_ASSERT_EQUAL_UINT8(50, settings.mapSettings.minPolygonSize);
  TEST_ASSERT_EQUAL_UINT8(2, settings.mapSettings.detailLevel);
  TEST_ASSERT_EQUAL_UINT8(2, settings.mapSettings.routeLineWidth);
  TEST_ASSERT_EQUAL_UINT8(3, settings.mapSettings.displayRotation);
  TEST_ASSERT_EQUAL_UINT8(1, settings.mapSettings.mapRotationMode);
  TEST_ASSERT_EQUAL_UINT8(5, settings.mapSettings.zoomLevel);
  TEST_ASSERT_EQUAL_UINT32(3735928559UL, settings.mapSettings.visibilityMask);
  TEST_ASSERT_EQUAL_UINT8(24, settings.mapSettings.streetLineWidthBoost);
  TEST_ASSERT_EQUAL_UINT8(1, settings.mapSettings.positionMarkerScale);
  TEST_ASSERT_EQUAL_UINT8(1, settings.mapSettings.tapToSwitchScreens);
}

void testNegativePersistedPowerValuesClampLow() {
  const char text[] =
      "brightness=-10\n"
      "battery_scale_permille=-1\n";

  const xiao_round::settings_core::DeviceSettings settings =
      xiao_round::settings_core::parseSettingsText(text);

  TEST_ASSERT_EQUAL_UINT8(5, settings.brightnessPercent);
  TEST_ASSERT_EQUAL_UINT16(1000, settings.batteryScalePermille);
}

void testPrefixedKeysDoNotOverrideStoredValues() {
  const char text[] =
      "old_brightness=5\n"
      "brightness=70\n"
      "old_battery_scale_permille=4000\n"
      "battery_scale_permille=2100\n";

  const xiao_round::settings_core::DeviceSettings settings =
      xiao_round::settings_core::parseSettingsText(text);

  TEST_ASSERT_EQUAL_UINT8(70, settings.brightnessPercent);
  TEST_ASSERT_EQUAL_UINT16(2100, settings.batteryScalePermille);
}

void testFormatsBatteryScaleAndRoundTripsSettings() {
  xiao_round::settings_core::DeviceSettings settings;
  settings.brightnessPercent = 75;
  settings.batteryScalePermille = 2050;
  settings.mapSettings.minPolygonSize = 12;
  settings.mapSettings.detailLevel = 1;
  settings.mapSettings.routeLineWidth = 8;
  settings.mapSettings.displayRotation = 2;
  settings.mapSettings.mapRotationMode = 1;
  settings.mapSettings.zoomLevel = 4;
  settings.mapSettings.visibilityMask = 0x12345678UL;
  settings.mapSettings.streetLineWidthBoost = 3;
  settings.mapSettings.positionMarkerScale = 2;
  settings.mapSettings.tapToSwitchScreens = 0;

  char buffer[320] = {};
  const size_t written =
      xiao_round::settings_core::formatSettingsText(settings, buffer,
                                                    sizeof(buffer));
  TEST_ASSERT_GREATER_THAN_UINT32(0, written);
  TEST_ASSERT_NOT_NULL(strstr(buffer, "battery_scale_permille=2050\n"));

  const xiao_round::settings_core::DeviceSettings parsed =
      xiao_round::settings_core::parseSettingsText(buffer);
  TEST_ASSERT_EQUAL_UINT8(settings.brightnessPercent,
                          parsed.brightnessPercent);
  TEST_ASSERT_EQUAL_UINT16(settings.batteryScalePermille,
                           parsed.batteryScalePermille);
  TEST_ASSERT_EQUAL_UINT8(settings.mapSettings.minPolygonSize,
                          parsed.mapSettings.minPolygonSize);
  TEST_ASSERT_EQUAL_UINT8(settings.mapSettings.mapRotationMode,
                          parsed.mapSettings.mapRotationMode);
  TEST_ASSERT_EQUAL_UINT32(settings.mapSettings.visibilityMask,
                           parsed.mapSettings.visibilityMask);
}

void testFormatterRejectsTooSmallBuffersWithoutPartialText() {
  xiao_round::settings_core::DeviceSettings settings;
  char buffer[8] = {'x', 'x', 'x', '\0'};

  const size_t written =
      xiao_round::settings_core::formatSettingsText(settings, buffer,
                                                    sizeof(buffer));

  TEST_ASSERT_EQUAL_UINT32(0, written);
  TEST_ASSERT_EQUAL_STRING("", buffer);
}

} // namespace

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(testDefaultsWhenSettingsTextIsMissing);
  RUN_TEST(testParsesAndClampsBatteryBrightnessAndMapSettings);
  RUN_TEST(testNegativePersistedPowerValuesClampLow);
  RUN_TEST(testPrefixedKeysDoNotOverrideStoredValues);
  RUN_TEST(testFormatsBatteryScaleAndRoundTripsSettings);
  RUN_TEST(testFormatterRejectsTooSmallBuffersWithoutPartialText);
  return UNITY_END();
}
